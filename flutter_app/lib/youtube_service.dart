import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class YoutubeService {
  final YoutubeExplode _yt = YoutubeExplode();

  /// Gets video info including thumbnail, title, author, duration
  Future<Map<String, dynamic>> getVideoInfo(String url) async {
    try {
      var video = await _yt.videos.get(url);
      
      return {
        'id': video.id.value,
        'title': video.title,
        'author': video.author,
        'duration': video.duration?.inSeconds ?? 0,
        'thumbnail': video.thumbnails.highResUrl,
        'url': url,
      };
    } catch (e) {
      throw Exception('Video load karne mein masla hua. Sahi link daalein. ($e)');
    }
  }

  /// Gets streams for a video
  Future<Map<String, dynamic>> getStreams(String videoId) async {
    try {
      var manifest = await _yt.videos.streamsClient.getManifest(videoId);
      
      List<Map<String, dynamic>> formats = [];

      // Add Muxed streams (Video + Audio combined, usually up to 720p)
      for (var streamInfo in manifest.muxed) {
        formats.add({
          'format_id': 'muxed_${streamInfo.videoQuality.name}',
          'resolution': streamInfo.videoQuality.name,
          'ext': streamInfo.container.name,
          'filesize': streamInfo.size.totalBytes,
          'url': streamInfo.url.toString(),
          'type': 'muxed',
        });
      }

      // Add Video-only streams (for 1080p, 2K, 4K)
      var videoOnly = manifest.videoOnly.sortByVideoQuality();
      for (var streamInfo in videoOnly) {
        // Filter only mp4/webm to keep it simple
        if (streamInfo.container.name == 'mp4' || streamInfo.container.name == 'webm') {
           formats.add({
            'format_id': 'video_${streamInfo.videoQuality.name}_${streamInfo.container.name}',
            'resolution': streamInfo.videoQuality.name, // e.g. 1080p, 2160p
            'ext': streamInfo.container.name,
            'filesize': streamInfo.size.totalBytes,
            'url': streamInfo.url.toString(),
            'type': 'video_only',
            'bitrate': streamInfo.bitrate.bitsPerSecond,
          });
        }
      }

      // Add highest quality Audio stream (to mix with video-only, or standalone audio)
      var audioStream = manifest.audioOnly.withHighestBitrate();
      formats.add({
        'format_id': 'audio_only',
        'resolution': 'Audio Only',
        'ext': audioStream.container.name,
        'filesize': audioStream.size.totalBytes,
        'url': audioStream.url.toString(),
        'type': 'audio_only',
        'bitrate': audioStream.bitrate.bitsPerSecond,
      });
      
      // Best Audio URL (used for merging)
      String bestAudioUrl = audioStream.url.toString();

      return {
        'formats': formats,
        'best_audio_url': bestAudioUrl,
        'best_audio_ext': audioStream.container.name,
      };
    } catch (e) {
      throw Exception('Streams nikalne mein error: $e');
    }
  }

  void dispose() {
    _yt.close();
  }
}
