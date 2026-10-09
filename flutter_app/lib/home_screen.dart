import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import 'youtube_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _urlController = TextEditingController();
  final YoutubeService _ytService = YoutubeService();
  bool _isLoading = false;
  Map<String, dynamic>? _videoInfo;
  Map<String, dynamic>? _streamsInfo;

  // Download State
  bool _isDownloading = false;
  bool _isPaused = false;
  bool _isMerging = false;
  double _progress = 0.0;
  String _statusText = '';
  
  // Dio
  CancelToken? _dioCancelToken;
  String? _downloadedFilePath;
  int _downloadedFileBytes = 0;
  
  // Merging temp files
  String? _tempVideoPath;
  String? _tempAudioPath;

  // ── Helpers ────────────────────────────────────────────────────────────

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 14)),
        backgroundColor: isError ? const Color(0xFFD32F2F) : const Color(0xFF388E3C),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes > 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (bytes > 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  String _formatDuration(dynamic seconds) {
    if (seconds == null) return '';
    final s = (seconds is num) ? seconds.toInt() : int.tryParse(seconds.toString()) ?? 0;
    if (s <= 0) return '';
    final m = s ~/ 60;
    final sec = s % 60;
    if (m > 60) {
      final h = m ~/ 60;
      final min = m % 60;
      return '${h}h ${min}m';
    }
    return '${m}:${sec.toString().padLeft(2, '0')}';
  }

  // ── Analyze URL ────────────────────────────────────────────────────────

  Future<void> _analyzeUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _showSnack('Please paste a URL first', isError: true);
      return;
    }

    setState(() {
      _isLoading = true;
      _videoInfo = null;
      _streamsInfo = null;
    });

    try {
      final info = await _ytService.getVideoInfo(url);
      final streams = await _ytService.getStreams(info['id']);
      setState(() {
        _videoInfo = info;
        _streamsInfo = streams;
      });
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Directory Setup ────────────────────────────────────────────────────

  Future<Directory> _getSamTubeDir() async {
    final downloadDir = Directory('/storage/emulated/0/Download/SamTube');
    try {
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      return downloadDir;
    } catch (_) {
      final appDir = await getApplicationDocumentsDirectory();
      final samtubeDir = Directory('${appDir.path}/SamTube');
      if (!await samtubeDir.exists()) {
        await samtubeDir.create(recursive: true);
      }
      return samtubeDir;
    }
  }
  
  Future<Directory> _getTempDir() async {
    return await getTemporaryDirectory();
  }

  // ── Single File Download ───────────────────────────────────────────────

  Future<void> _startSingleDownload(Map<String, dynamic> format) async {
    setState(() {
      _isDownloading = true;
      _isPaused = false;
      _progress = 0.0;
      _statusText = 'Preparing download...';
      _downloadedFileBytes = 0;
    });

    try {
      var status = await Permission.storage.request();
      if (status.isDenied) {
        status = await Permission.manageExternalStorage.request();
      }

      final baseDir = await _getSamTubeDir();
      final sanitizedTitle = (_videoInfo!['title'] ?? 'video').toString().replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
      final ext = format['ext'] ?? 'mp4';
      final savePath = '${baseDir.path}/$sanitizedTitle.$ext';
      _downloadedFilePath = savePath;

      await _downloadFile(format['url'], savePath, (progress, total) {
        if (mounted) {
          setState(() {
            _progress = total > 0 ? progress / total : 0;
            _statusText = 'Downloading: ${_formatBytes(progress)} / ${_formatBytes(total)}';
          });
        }
      });

      if (!_isPaused && mounted) {
        setState(() {
          _statusText = 'Saved ✅';
          _isDownloading = false;
        });
        _showSnack('Saved to Download/SamTube 🎉');
      }
    } catch (e) {
      if (!_isPaused) {
        _showSnack('Download failed: $e', isError: true);
        setState(() => _isDownloading = false);
      }
    }
  }

  // ── Dual Download (Video + Audio) & Merge ─────────────────────────────

  Future<void> _startDualDownload(Map<String, dynamic> videoFormat, String audioUrl, String audioExt) async {
    setState(() {
      _isDownloading = true;
      _isPaused = false;
      _isMerging = false;
      _progress = 0.0;
      _statusText = 'Preparing 4K/1080p download...';
    });

    try {
      var status = await Permission.storage.request();
      if (status.isDenied) status = await Permission.manageExternalStorage.request();

      final tempDir = await _getTempDir();
      final baseDir = await _getSamTubeDir();
      
      final sanitizedTitle = (_videoInfo!['title'] ?? 'video').toString().replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
      
      _tempVideoPath = '${tempDir.path}/temp_video.mp4';
      _tempAudioPath = '${tempDir.path}/temp_audio.$audioExt';
      final finalSavePath = '${baseDir.path}/$sanitizedTitle.mp4';

      // 1. Download Video Stream
      setState(() => _statusText = 'Downloading High-Res Video... (1/2)');
      await _downloadFile(videoFormat['url'], _tempVideoPath!, (progress, total) {
        if (mounted) {
          setState(() {
            _progress = total > 0 ? (progress / total) * 0.45 : 0; // 45% of total task
            _statusText = 'Video Stream: ${_formatBytes(progress)} / ${_formatBytes(total)}';
          });
        }
      });
      if (_isPaused) return;

      // 2. Download Audio Stream
      setState(() => _statusText = 'Downloading Audio... (2/2)');
      _downloadedFileBytes = 0; // Reset for audio
      await _downloadFile(audioUrl, _tempAudioPath!, (progress, total) {
        if (mounted) {
          setState(() {
            _progress = 0.45 + (total > 0 ? (progress / total) * 0.45 : 0); // Next 45%
            _statusText = 'Audio Stream: ${_formatBytes(progress)} / ${_formatBytes(total)}';
          });
        }
      });
      if (_isPaused) return;

      // 3. Merge with FFmpeg
      setState(() {
        _isMerging = true;
        _progress = 0.90;
        _statusText = 'Merging Audio & Video... Please wait.';
      });
      
      final command = '-y -i "$_tempVideoPath" -i "$_tempAudioPath" -c:v copy -c:a aac "$finalSavePath"';
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      
      // Cleanup temp files
      final vFile = File(_tempVideoPath!);
      final aFile = File(_tempAudioPath!);
      if (vFile.existsSync()) vFile.deleteSync();
      if (aFile.existsSync()) aFile.deleteSync();

      if (ReturnCode.isSuccess(returnCode)) {
        if (mounted) {
          setState(() {
            _progress = 1.0;
            _statusText = 'Saved ✅';
            _isDownloading = false;
            _isMerging = false;
          });
        }
        _showSnack('High Quality Video Saved! 🎉');
      } else {
        throw Exception('Merging failed');
      }

    } catch (e) {
      if (!_isPaused) {
        _showSnack('Download failed: $e', isError: true);
        setState(() {
          _isDownloading = false;
          _isMerging = false;
        });
      }
    }
  }

  // ── Dio Download Core ──────────────────────────────────────────────────

  Future<void> _downloadFile(String url, String savePath, Function(int, int) onProgress) async {
    _dioCancelToken = CancelToken();
    final dio = Dio();
    dio.options.connectTimeout = const Duration(seconds: 30);
    dio.options.receiveTimeout = const Duration(minutes: 30);

    final headers = <String, dynamic>{};
    if (_downloadedFileBytes > 0) {
      headers['Range'] = 'bytes=$_downloadedFileBytes-';
    }

    try {
      final response = await dio.get<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream, headers: headers),
        cancelToken: _dioCancelToken,
      );

      final file = File(savePath);
      final raf = file.openSync(mode: _downloadedFileBytes > 0 ? FileMode.append : FileMode.write);

      int received = 0;
      final contentLengthStr = response.headers.value(Headers.contentLengthHeader) ?? '';
      final contentLength = int.tryParse(contentLengthStr) ?? 0;
      final totalExpected = contentLength > 0 ? contentLength + _downloadedFileBytes : 0;

      try {
        await for (final chunk in response.data!.stream) {
          if (_dioCancelToken!.isCancelled) break;
          raf.writeFromSync(chunk);
          received += chunk.length;
          onProgress(received + _downloadedFileBytes, totalExpected);
        }
      } finally {
        raf.closeSync();
      }

      if (_dioCancelToken!.isCancelled) {
        _downloadedFileBytes = file.statSync().size;
        _isPaused = true;
      } else {
        _downloadedFileBytes = 0;
      }
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        final file = File(savePath);
        if (file.existsSync()) _downloadedFileBytes = file.statSync().size;
        _isPaused = true;
      } else {
        rethrow;
      }
    }
  }

  // ── Pause / Cancel ─────────────────────────────────────────────────────

  void _pauseDownload() {
    if (_isMerging) {
      _showSnack('Cannot pause while merging files.');
      return;
    }
    _dioCancelToken?.cancel('Paused by user');
    setState(() {
      _isPaused = true;
      _statusText = 'Paused';
    });
  }

  void _cancelDownload() {
    _dioCancelToken?.cancel();
    // Cleanup
    if (_downloadedFilePath != null) {
      final f = File(_downloadedFilePath!);
      if (f.existsSync()) f.deleteSync();
    }
    if (_tempVideoPath != null) {
      final f = File(_tempVideoPath!);
      if (f.existsSync()) f.deleteSync();
    }
    if (_tempAudioPath != null) {
      final f = File(_tempAudioPath!);
      if (f.existsSync()) f.deleteSync();
    }
    
    setState(() {
      _isDownloading = false;
      _isPaused = false;
      _isMerging = false;
      _statusText = '';
      _downloadedFileBytes = 0;
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _ytService.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ── BUILD UI ──────────────────────────────────────────────────────────
  // ═══════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              floating: true,
              backgroundColor: const Color(0xFF0D0D0D),
              surfaceTintColor: Colors.transparent,
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFFFF1744), Color(0xFFD50000)]),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'SamTube',
                    style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 22, color: Colors.white),
                  ),
                  const Spacer(),
                  const Icon(Icons.phone_android, color: Colors.green, size: 16),
                  const SizedBox(width: 4),
                  Text('Native', style: GoogleFonts.inter(color: Colors.green, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
              systemOverlayStyle: SystemUiOverlayStyle.light,
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  const SizedBox(height: 8),
                  _buildSearchBox(),
                  const SizedBox(height: 20),
                  if (_isDownloading) ...[
                    _buildProgressCard(),
                    const SizedBox(height: 20),
                  ],
                  if (_videoInfo != null && !_isDownloading) _buildVideoInfoCard(),
                  const SizedBox(height: 40),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Components ─────────────────────────────────────────────────────────

  Widget _buildSearchBox() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.link_rounded, color: Color(0xFF666666), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _urlController,
              style: GoogleFonts.inter(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Paste video URL here...',
                hintStyle: GoogleFonts.inter(color: const Color(0xFF555555)),
                border: InputBorder.none,
                isDense: true,
              ),
              onSubmitted: (_) => _analyzeUrl(),
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _isLoading ? null : _analyzeUrl,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                decoration: BoxDecoration(
                  gradient: _isLoading ? null : const LinearGradient(colors: [Color(0xFFFF1744), Color(0xFFD50000)]),
                  color: _isLoading ? const Color(0xFF333333) : null,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _isLoading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.search_rounded, color: Colors.white, size: 22),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [const Color(0xFF1A1A1A), _isPaused ? const Color(0xFF1A1500) : const Color(0xFF1A0A0A)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _isPaused ? Colors.orange.withAlpha(60) : const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: (_isPaused ? Colors.orange : Colors.red).withAlpha(25),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _isPaused ? Icons.pause_circle_filled : (_isMerging ? Icons.merge_type : Icons.downloading_rounded),
                  color: _isPaused ? Colors.orange : Colors.red,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isPaused ? 'Download Paused' : (_isMerging ? 'Processing...' : 'Downloading...'),
                      style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    Text(_statusText, style: GoogleFonts.inter(color: const Color(0xFF888888), fontSize: 13)),
                  ],
                ),
              ),
              Text(
                '${(_progress * 100).toStringAsFixed(0)}%',
                style: GoogleFonts.poppins(color: _isPaused ? Colors.orange : Colors.red, fontWeight: FontWeight.w700, fontSize: 20),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _progress,
              backgroundColor: const Color(0xFF2A2A2A),
              valueColor: AlwaysStoppedAnimation<Color>(_isPaused ? Colors.orange : Colors.red),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              if (!_isMerging)
                Expanded(
                  child: _actionButton(
                    onPressed: _isPaused ? () {} : _pauseDownload, // Native resume logic is complex for dual stream, simplified for now
                    icon: _isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    label: _isPaused ? 'Paused' : 'Pause',
                    color: _isPaused ? Colors.grey : Colors.orange,
                  ),
                ),
              if (!_isMerging) const SizedBox(width: 12),
              Expanded(
                child: _actionButton(
                  onPressed: _cancelDownload,
                  icon: Icons.close_rounded,
                  label: 'Cancel',
                  color: const Color(0xFFD32F2F),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionButton({required VoidCallback onPressed, required IconData icon, required String label, required Color color}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(border: Border.all(color: color.withAlpha(80)), borderRadius: BorderRadius.circular(12), color: color.withAlpha(15)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(label, style: GoogleFonts.inter(color: color, fontWeight: FontWeight.w600, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoInfoCard() {
    final formats = (_streamsInfo?['formats'] as List? ?? []);
    final muxed = formats.where((f) => f['type'] == 'muxed').toList();
    final videoOnly = formats.where((f) => f['type'] == 'video_only').toList();
    final audio = formats.where((f) => f['type'] == 'audio_only').toList();
    final bestAudioUrl = _streamsInfo?['best_audio_url'];
    final bestAudioExt = _streamsInfo?['best_audio_ext'] ?? 'm4a';

    final duration = _formatDuration(_videoInfo!['duration']);

    return Container(
      decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF2A2A2A))),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              Image.network(
                _videoInfo!['thumbnail'], width: double.infinity, height: 210, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(height: 210, color: const Color(0xFF2A2A2A), child: const Center(child: Icon(Icons.image_not_supported))),
              ),
              if (duration.isNotEmpty)
                Positioned(bottom: 8, right: 8, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.black.withAlpha(200), borderRadius: BorderRadius.circular(6)), child: Text(duration, style: GoogleFonts.inter(color: Colors.white, fontSize: 12)))),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_videoInfo!['title']?.toString() ?? 'Unknown', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Row(children: [const Icon(Icons.person_outline, color: Colors.grey, size: 16), const SizedBox(width: 6), Expanded(child: Text(_videoInfo!['author']?.toString() ?? '', style: GoogleFonts.inter(fontSize: 13, color: Colors.grey)))]),
                const SizedBox(height: 24),
                
                // HIGH RES (Requires Merging)
                if (videoOnly.isNotEmpty) ...[
                  Row(children: [const Icon(Icons.hd_rounded, color: Colors.blueAccent, size: 18), const SizedBox(width: 8), Text('High Quality (1080p, 2K, 4K)', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white))]),
                  const SizedBox(height: 4),
                  Text('Inko download aur merge hone mein thora time lagega.', style: GoogleFonts.inter(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 10),
                  ...videoOnly.take(3).map((fmt) => _buildFormatTile(
                    icon: Icons.high_quality_rounded, title: fmt['resolution'], subtitle: '${fmt['ext'].toString().toUpperCase()} + Audio Merge', filesize: fmt['filesize'], color: Colors.blueAccent,
                    onTap: () => _startDualDownload(fmt, bestAudioUrl, bestAudioExt),
                  )),
                  const SizedBox(height: 20),
                ],

                // STANDARD (Direct)
                if (muxed.isNotEmpty) ...[
                  Row(children: [const Icon(Icons.videocam_rounded, color: Colors.green, size: 18), const SizedBox(width: 8), Text('Standard Quality (Fast)', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white))]),
                  const SizedBox(height: 10),
                  ...muxed.take(3).map((fmt) => _buildFormatTile(
                    icon: Icons.video_file_rounded, title: fmt['resolution'], subtitle: fmt['ext'].toString().toUpperCase(), filesize: fmt['filesize'], color: Colors.green,
                    onTap: () => _startSingleDownload(fmt),
                  )),
                  const SizedBox(height: 20),
                ],

                // AUDIO ONLY
                if (audio.isNotEmpty) ...[
                  Row(children: [const Icon(Icons.audiotrack_rounded, color: Colors.red, size: 18), const SizedBox(width: 8), Text('Audio Only', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white))]),
                  const SizedBox(height: 10),
                  _buildFormatTile(
                    icon: Icons.music_note_rounded, title: 'High Quality Audio', subtitle: audio.first['ext'].toString().toUpperCase(), filesize: audio.first['filesize'], color: Colors.red,
                    onTap: () => _startSingleDownload(audio.first),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormatTile({required IconData icon, required String title, required String subtitle, dynamic filesize, required VoidCallback onTap, required Color color}) {
    String sizeStr = filesize != null ? _formatBytes(filesize) : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: const Color(0xFF222222), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF2E2E2E))),
            child: Row(
              children: [
                Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: color.withAlpha(20), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: color, size: 20)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(sizeStr.isNotEmpty ? '$subtitle  •  $sizeStr' : subtitle, style: GoogleFonts.inter(color: const Color(0xFF777777), fontSize: 12)),
                    ],
                  ),
                ),
                Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: color.withAlpha(40), borderRadius: BorderRadius.circular(10)), child: Icon(Icons.download_rounded, color: color, size: 18)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
