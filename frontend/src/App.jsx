import { useState, useEffect, useRef } from 'react'
import './App.css'

const API_BASE = 'http://localhost:8000'
const WS_BASE = 'ws://localhost:8000'

function formatBytes(bytes) {
  if (!bytes) return 'Unknown size'
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`
}

function formatDuration(seconds) {
  if (!seconds) return '--:--'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  const s = Math.floor(seconds % 60)
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
  return `${m}:${String(s).padStart(2, '0')}`
}

function generateClientId() {
  return Math.random().toString(36).substring(2, 15)
}

export default function App() {
  const [url, setUrl] = useState('')
  const [videoInfo, setVideoInfo] = useState(null)
  const [isAnalyzing, setIsAnalyzing] = useState(false)
  const [selectedFormat, setSelectedFormat] = useState('')
  const [downloads, setDownloads] = useState([]) // { clientId, status, percent, filename, message, downloadUrl }
  const [error, setError] = useState('')
  const [ffmpegStatus, setFfmpegStatus] = useState({ available: true, message: '' })
  const [queueStatus, setQueueStatus] = useState({ active: 0, queued: 0 })
  const wsRefs = useRef({})

  // Check FFmpeg and Queue Status on mount
  useEffect(() => {
    const checkStatus = async () => {
      try {
        const ffRes = await fetch(`${API_BASE}/check-ffmpeg`)
        const ffData = await ffRes.json()
        setFfmpegStatus({ available: ffData.ffmpeg_available, message: ffData.message })

        const qRes = await fetch(`${API_BASE}/queue-status`)
        const qData = await qRes.json()
        setQueueStatus({ active: qData.active, queued: qData.queued })
      } catch (e) {
        console.error("Failed to connect to backend", e)
      }
    }
    
    checkStatus()
    const interval = setInterval(checkStatus, 5000)
    return () => clearInterval(interval)
  }, [])

  // Helper: unique formats deduped by resolution label
  const getUniqueFormats = (formats) => {
    const seen = new Set()
    const unique = []
    unique.push({ format_id: 'audio', resolution: 'Audio Only (MP3)', ext: 'mp3', filesize: null })
    for (const f of formats) {
      const label = f.resolution || f.note
      if (label && !seen.has(label) && f.resolution !== 'N/A' && !label.includes('null')) {
        seen.add(label)
        unique.push(f)
      }
    }
    return unique
  }

  const handleAnalyze = async () => {
    if (!url.trim()) return
    setError('')
    setVideoInfo(null)
    setSelectedFormat('')
    setIsAnalyzing(true)
    try {
      const res = await fetch(`${API_BASE}/analyze`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: url.trim() })
      })
      const data = await res.json()
      if (data.error) { setError(data.error); return }
      setVideoInfo(data)
    } catch (e) {
      setError('Cannot connect to backend. Make sure the server is running.')
    } finally {
      setIsAnalyzing(false)
    }
  }

  const handleDownload = () => {
    if (!selectedFormat || !videoInfo) return
    const clientId = generateClientId()
    const newDownload = { clientId, status: 'queued', percent: '0%', filename: videoInfo.title, message: 'Queued...', downloadUrl: null }
    setDownloads(prev => [newDownload, ...prev])

    const ws = new WebSocket(`${WS_BASE}/ws/${clientId}`)
    wsRefs.current[clientId] = ws

    ws.onmessage = (event) => {
      const data = JSON.parse(event.data)
      setDownloads(prev => prev.map(d => {
        if (d.clientId !== clientId) return d
        
        if (data.status === 'downloading') {
          return { ...d, status: 'downloading', percent: data.percent || '0%', message: `Speed: ${data.speed ? (data.speed / 1024).toFixed(0) + ' KB/s' : '...'} | ETA: ${data.eta ? data.eta + 's' : '...'}` }
        }
        if (data.status === 'finished') {
          return { ...d, status: 'merging', percent: '99%', message: 'Merging audio & video with FFmpeg...' }
        }
        if (data.status === 'complete') {
          ws.close()
          // Auto-trigger browser download
          if (data.download_url) {
            const link = document.createElement('a')
            link.href = data.download_url
            link.setAttribute('download', data.filename || 'video.mp4')
            document.body.appendChild(link)
            link.click()
            document.body.removeChild(link)
          }
          return { ...d, status: 'complete', percent: '100%', message: 'Download Complete! Saving to browser...', downloadUrl: data.download_url }
        }
        if (data.status === 'error') {
          ws.close()
          return { ...d, status: 'error', percent: '0%', message: data.message }
        }
        if (data.status === 'queued') {
            return { ...d, status: 'queued', message: data.message }
        }
        return d
      }))
    }

    ws.onopen = () => {
      fetch(`${API_BASE}/download`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          url: videoInfo.original_url,
          format_id: selectedFormat,
          client_id: clientId
        })
      })
    }
  }

  const handleCancel = async (clientId) => {
    try {
      await fetch(`${API_BASE}/cancel/${clientId}`, { method: 'POST' })
    } catch (e) {
      console.error("Failed to cancel download", e)
    }
  }

  const handleRemoveItem = (clientId) => {
    setDownloads(prev => prev.filter(d => d.clientId !== clientId));
  }

  const uniqueFormats = videoInfo ? getUniqueFormats(videoInfo.formats) : []

  return (
    <div className="min-h-screen bg-[#0a0a0a] text-white font-['Inter',sans-serif] app-container">
      <div className="glow-bg">
        <div className="glow-1" />
        <div className="glow-2" />
      </div>

      <div className="relative z-10 max-w-4xl mx-auto px-4 py-12 w-full main-content">
        {/* Header */}
        <div className="text-center mb-12">
          <div className="inline-flex items-center gap-3 mb-4">
            <div className="w-14 h-14 rounded-2xl flex items-center justify-center shadow-[0_0_30px_rgba(0,242,255,0.35)] overflow-hidden" style={{background: 'linear-gradient(135deg, #00f2ff, #bc00ff)'}}>
              <img src="/samtube.png" alt="SamTube Logo" className="w-full h-full object-cover" />
            </div>
            <h1 className="text-5xl font-bold font-['Outfit',sans-serif] tracking-tight" style={{background: 'linear-gradient(90deg, #00f2ff, #bc00ff)', WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent'}}>
              SamTube
            </h1>
          </div>
          <p className="text-gray-400 text-lg max-w-md mx-auto leading-relaxed">Download YouTube videos directly to your browser with perfect A/V sync.</p>
          
          <div className="mt-6 flex items-center justify-center gap-4 text-xs font-semibold uppercase tracking-widest">
            {!ffmpegStatus.available && (
               <div className="px-3 py-1.5 rounded-full bg-red-500/10 border border-red-500/20 text-red-400 flex items-center gap-2">
                 <span className="w-2 h-2 rounded-full bg-red-500 animate-pulse"></span>
                 FFmpeg Missing
               </div>
            )}
            <div className="px-3 py-1.5 rounded-full bg-blue-500/10 border border-blue-500/20 text-blue-400 flex items-center gap-2">
              <span className="w-2 h-2 rounded-full bg-blue-400"></span>
              {queueStatus.active} Active / {queueStatus.queued} Queued
            </div>
          </div>
        </div>

        {/* URL Input */}
        <div className="glass-card rounded-3xl p-8 mb-8 border-white/5 shadow-2xl">
          <label className="text-xs font-bold uppercase tracking-[0.2em] text-gray-500 mb-4 block">Enter Video URL</label>
          <div className="flex flex-col sm:flex-row gap-4">
            <div className="relative flex-1">
               <input
                type="text"
                value={url}
                onChange={e => setUrl(e.target.value)}
                onKeyDown={e => e.key === 'Enter' && handleAnalyze()}
                placeholder="Paste YouTube link here..."
                className="w-full bg-black/40 border border-white/10 rounded-2xl px-6 py-4 text-base text-white placeholder-gray-600 focus:outline-none focus:border-[#00f2ff] focus:ring-1 focus:ring-[#00f2ff]/30 transition-all duration-300"
              />
              {url && (
                <button onClick={() => setUrl('')} className="absolute right-4 top-1/2 -translate-y-1/2 text-gray-500 hover:text-white transition-colors">
                    <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M6 18L18 6M6 6l12 12"/></svg>
                </button>
              )}
            </div>
            <button
              onClick={handleAnalyze}
              disabled={isAnalyzing || !url.trim()}
              className="px-8 py-4 rounded-2xl font-bold text-sm text-black transition-all duration-300 disabled:opacity-40 disabled:cursor-not-allowed hover:shadow-[0_0_20px_rgba(0,242,255,0.4)] active:scale-95 whitespace-nowrap"
              style={{background: 'linear-gradient(90deg, #00f2ff, #bc00ff)'}}
            >
              <span className="relative z-10 flex items-center justify-center gap-2">
                {isAnalyzing ? (
                  <>
                    <svg className="w-4 h-4 animate-spin" fill="none" viewBox="0 0 24 24">
                      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
                      <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8z"/>
                    </svg>
                    Analyzing...
                  </>
                ) : (
                  <>
                    <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/></svg>
                    Fetch Info
                  </>
                )}
              </span>
            </button>
          </div>
          {error && <p className="mt-4 text-red-400 text-sm flex items-center gap-2 animate-fadeIn"><span>⚠</span>{error}</p>}
        </div>

        {/* Video Info & Options */}
        {videoInfo && (
          <div className="animate-fadeIn">
            <div className="glass-card rounded-3xl overflow-hidden mb-8 border-white/5">
                <div className="md:flex">
                    <div className="md:w-1/3 relative group">
                        <img src={videoInfo.thumbnail} alt="Thumbnail" className="w-full h-full object-cover aspect-video md:aspect-auto" />
                        <div className="absolute inset-0 bg-black/40 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
                             <div className="bg-black/60 rounded-full p-3 backdrop-blur-sm">
                                <svg className="w-8 h-8 text-[#00f2ff]" fill="currentColor" viewBox="0 0 20 20"><path fillRule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM9.555 7.168A1 1 0 008 8v4a1 1 0 001.555.832l3-2a1 1 0 000-1.664l-3-2z" clipRule="evenodd"/></svg>
                             </div>
                        </div>
                        <div className="absolute bottom-3 right-3 bg-black/80 px-2 py-1 rounded text-[10px] font-bold text-white backdrop-blur-md">
                            {formatDuration(videoInfo.duration)}
                        </div>
                    </div>
                    <div className="p-8 md:w-2/3 flex flex-col justify-center">
                        <h2 className="font-bold text-white text-xl leading-tight mb-3 line-clamp-2 font-['Outfit',sans-serif]">{videoInfo.title}</h2>
                        <div className="flex flex-wrap gap-4 text-sm text-gray-400">
                            <span className="flex items-center gap-1.5"><svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"/></svg>{videoInfo.uploader}</span>
                            <span className="flex items-center gap-1.5"><svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>{formatDuration(videoInfo.duration)}</span>
                        </div>
                    </div>
                </div>
                
                <div className="p-8 border-t border-white/5 bg-white/[0.02]">
                    <label className="text-[10px] font-bold uppercase tracking-[0.2em] text-gray-500 mb-5 block">Select Resolution & Format</label>
                    <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
                        {uniqueFormats.map((f) => (
                            <button
                                key={f.format_id}
                                onClick={() => setSelectedFormat(f.format_id)}
                                className={`p-4 rounded-2xl border text-left transition-all group relative overflow-hidden ${
                                    selectedFormat === f.format_id
                                        ? 'border-[#00f2ff] bg-[#00f2ff]/10 shadow-[0_0_15px_rgba(0,242,255,0.15)]'
                                        : 'border-white/5 bg-white/5 hover:bg-white/10 hover:border-white/10'
                                }`}
                            >
                                {selectedFormat === f.format_id && (
                                    <div className="absolute top-0 right-0 w-8 h-8 bg-[#00f2ff] flex items-center justify-center rounded-bl-xl">
                                        <svg className="w-4 h-4 text-black" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="3" d="M5 13l4 4L19 7"/></svg>
                                    </div>
                                )}
                                <div className={`font-bold text-sm mb-1 ${selectedFormat === f.format_id ? 'text-[#00f2ff]' : 'text-white'}`}>
                                    {f.resolution}
                                </div>
                                <div className="text-[10px] text-gray-500 font-medium">
                                    {f.filesize ? formatBytes(f.filesize) : f.ext?.toUpperCase() || 'MP4'}
                                    {f.height >= 1080 && <span className="ml-2 text-[#bc00ff] font-bold">HD</span>}
                                </div>
                            </button>
                        ))}
                    </div>

                    <button
                        onClick={handleDownload}
                        disabled={!selectedFormat || !ffmpegStatus.available}
                        className="w-full mt-8 py-5 rounded-2xl font-bold text-black text-base transition-all duration-300 disabled:opacity-40 disabled:cursor-not-allowed hover:shadow-[0_0_30px_rgba(188,0,255,0.3)] active:scale-95 group overflow-hidden relative"
                        style={{background: 'linear-gradient(90deg, #00f2ff, #bc00ff)'}}
                    >
                        <span className="relative z-10 flex items-center justify-center gap-3">
                            <svg className="w-6 h-6 animate-bounce" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>
                            Start Processing
                        </span>
                    </button>
                </div>
            </div>
          </div>
        )}

        {/* Downloads Queue */}
        {downloads.length > 0 && (
          <div className="space-y-4 animate-fadeIn">
            <div className="flex items-center justify-between mb-4">
                <h3 className="text-xs font-bold uppercase tracking-[0.2em] text-gray-500">Live Downloads</h3>
                <span className="text-[10px] text-gray-600 bg-white/5 px-2 py-1 rounded-lg">{downloads.length} Total</span>
            </div>
            <div className="grid gap-4">
                {downloads.map((d) => (
                <div key={d.clientId} className="glass-card rounded-2xl p-6 border-white/5 shadow-xl download-item">
                    <div className="flex items-start justify-between mb-4">
                    <div className="flex-1 min-w-0 mr-4">
                        <p className="font-bold text-sm text-white truncate font-['Outfit',sans-serif]">{d.filename}</p>
                        <p className="text-[10px] text-gray-500 mt-1 font-medium flex items-center gap-2">
                            {d.status === 'downloading' && <span className="flex h-1.5 w-1.5 rounded-full bg-[#00f2ff] animate-pulse"></span>}
                            {d.message}
                        </p>
                    </div>
                    <div className="flex gap-2">
                        {d.status === 'complete' && d.downloadUrl ? (
                             <>
                               <a 
                                  href={d.downloadUrl} 
                                  download={d.filename}
                                  className="status-badge border text-emerald-400 bg-emerald-400/10 border-emerald-400/20 hover:bg-emerald-400/20 transition-colors flex items-center gap-1.5"
                               >
                                  <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"/></svg>
                                  Save File
                               </a>
                               <button onClick={() => handleRemoveItem(d.clientId)} className="status-badge border text-gray-400 bg-gray-400/10 border-gray-400/20 hover:bg-gray-400/20 transition-colors flex items-center justify-center cursor-pointer px-2" title="Remove Item">
                                 <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M6 18L18 6M6 6l12 12"/></svg>
                               </button>
                             </>
                        ) : (
                            <>
                                {['downloading', 'queued', 'merging'].includes(d.status) && (
                                    <button 
                                        onClick={() => handleCancel(d.clientId)}
                                        className="status-badge border text-red-400 bg-red-400/10 border-red-400/20 hover:bg-red-400/20 transition-colors flex items-center gap-1.5 cursor-pointer"
                                        title="Cancel Download"
                                    >
                                        <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M6 18L18 6M6 6l12 12"/></svg>
                                        Cancel
                                    </button>
                                )}
                                <StatusBadge status={d.status} />
                                {d.status === 'error' && (
                                    <button onClick={() => handleRemoveItem(d.clientId)} className="status-badge border text-gray-400 bg-gray-400/10 border-gray-400/20 hover:bg-gray-400/20 transition-colors flex items-center justify-center cursor-pointer px-2" title="Remove Failed Item">
                                        <svg className="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/></svg>
                                    </button>
                                )}
                            </>
                        )}
                    </div>
                    </div>
                    
                    <div className="relative pt-1">
                        <div className="flex mb-2 items-center justify-between">
                            <div>
                                <span className="text-[10px] font-semibold inline-block text-[#00f2ff]">
                                    {d.status === 'complete' ? 'Success' : d.status === 'error' ? 'Failed' : d.status === 'merging' ? 'Processing' : 'Downloading'}
                                </span>
                            </div>
                            <div className="text-right">
                                <span className="text-[10px] font-bold inline-block text-white">
                                    {d.percent}
                                </span>
                            </div>
                        </div>
                        <div className="progress-bar-container">
                            <div
                                className="progress-bar-fill"
                                style={{
                                width: d.percent || '0%',
                                background: d.status === 'complete'
                                    ? 'linear-gradient(90deg, #00f2ff, #00ff88)'
                                    : d.status === 'error'
                                    ? '#ef4444'
                                    : 'linear-gradient(90deg, #00f2ff, #bc00ff)'
                                }}
                            />
                        </div>
                    </div>
                </div>
                ))}
            </div>
          </div>
        )}

        <div className="text-center mt-16 pb-8">
            <p className="text-gray-700 text-[10px] font-bold uppercase tracking-[0.3em]">SamTube Downloader Core v1.1</p>
            <p className="text-gray-800 text-[9px] mt-2 italic">Browser-direct download system active</p>
        </div>
      </div>
    </div>
  )
}

function StatusBadge({ status }) {
  const map = {
    queued: { label: 'Queued', color: 'text-amber-400 bg-amber-400/10 border-amber-400/20' },
    downloading: { label: 'Active', color: 'text-[#00f2ff] bg-[#00f2ff]/10 border-[#00f2ff]/20' },
    merging: { label: 'Merging', color: 'text-[#bc00ff] bg-[#bc00ff]/10 border-[#bc00ff]/20' },
    complete: { label: 'Ready', color: 'text-emerald-400 bg-emerald-400/10 border-emerald-400/20' },
    error: { label: 'Failed', color: 'text-red-400 bg-red-400/10 border-red-400/20' },
  }
  const s = map[status] || map.queued
  return (
    <span className={`status-badge border ${s.color}`}>{s.label}</span>
  )
}
