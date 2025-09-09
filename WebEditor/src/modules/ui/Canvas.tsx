import React, { useEffect, useRef } from 'react'
import { useDeckStore } from '../state/store'

export const Canvas: React.FC = () => {
  const deck = useDeckStore(s => s.deck)
  const sel = useDeckStore(s => s.selection)
  const slide = deck?.slides.find(s => s.id === sel.slideId) ?? deck?.slides[0]
  const holderRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const onReq = () => {
      // Render current slide to PNG using canvas2png approach via HTMLCanvasElement capture (simplified placeholder)
      // For now, take a rasterized image via toDataURL on an offscreen canvas copy
      const el = holderRef.current
      if (!el) return
      const scale = 2
      const w = 1600, h = 900
      const canvas = document.createElement('canvas')
      canvas.width = w
      canvas.height = h
      const ctx = canvas.getContext('2d')!
      ctx.fillStyle = '#0B1422'
      ctx.fillRect(0,0,w,h)
      ctx.fillStyle = '#E8F0FF'
      ctx.font = 'bold 56px Inter'
      ctx.fillText(slide?.title ?? 'Slide', 80, 160)
      const dataUrl = canvas.toDataURL('image/png')
      ;(window as any).webkit?.messageHandlers?.exportPDF?.postMessage({ images: [dataUrl] })
    }
    window.addEventListener('requestExportPDF' as any, onReq)
    return () => window.removeEventListener('requestExportPDF' as any, onReq)
  }, [slide])
  return (
    <div className="flex-1 flex items-center justify-center bg-black/10">
      <div ref={holderRef} className="relative" style={{ width: 800, height: 450 }}>
        <div className="absolute inset-0 rounded-xl card p-6">
          <div className="text-3xl font-semibold tracking-tight">{slide?.title ?? 'AI Presentation Creator'}</div>
          <div className="mt-4 text-sm text-muted">16:9 • 1600×900 logical • Nebula</div>
        </div>
      </div>
    </div>
  )
}


