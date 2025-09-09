import React, { useEffect } from 'react'
import { useDeckStore } from '../state/store'
import { exportDeckToPPTX } from '../export/pptx'
import { renderSlidesToPNGs } from '../export/pdf'

export const Toolbar: React.FC = () => {
  const deck = useDeckStore(s => s.deck)
  const theme = deck?.theme ?? 'Nebula'
  const title = deck?.title ?? 'Untitled Deck'
  const addSlide = useDeckStore(s => s.addSlideWithLayout)

  const exportMenu = () => {
    // Web triggers Swift bridges
    const exportPPTX = () => {
      if (!deck) return
      exportDeckToPPTX(deck).then(base64 => {
        ;(window as any).webkit?.messageHandlers?.exportPPTX?.postMessage({ pptxBase64: base64 })
      })
    }
    const exportPDF = () => {
      if (!deck) return
      const images = renderSlidesToPNGs(deck)
      ;(window as any).webkit?.messageHandlers?.exportPDF?.postMessage({ images })
    }
    const exportDeck = () => {
      if (!deck) return
      ;(window as any).webkit?.messageHandlers?.saveDeck?.postMessage({ deck })
    }
    return { exportPPTX, exportPDF, exportDeck }
  }

  const ex = exportMenu()
  const undo = useDeckStore(s => s.undo)
  const autosave = useDeckStore(s => s.autosave)

  useEffect(() => {
    const id = setInterval(() => autosave(), 10000)
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'z') {
        e.preventDefault()
        if (e.shiftKey) {
          // placeholder redo
        } else {
          undo()
        }
      }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'e') {
        e.preventDefault()
        ex.exportPPTX()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => { clearInterval(id); window.removeEventListener('keydown', onKey) }
  }, [undo])

  return (
    <div className="flex items-center justify-between px-4 py-2 border-b border-white/10 bg-black/20">
      <div className="flex items-center gap-3">
        <div className="bg-transparent text-xl font-semibold tracking-tight">{title}</div>
        <div className="text-sm text-muted">{theme}</div>
      </div>
      <div className="flex items-center gap-2">
        <button className="px-3 py-1 rounded bg-white/10 hover:bg-white/15">Templates</button>
        <div className="relative group">
          <button className="px-3 py-1 rounded bg-white/10 hover:bg-white/15">Add Slide ▾</button>
          <div className="hidden group-hover:block absolute right-0 mt-2 w-48 card p-2 text-sm space-y-1">
            {(['title','title-bullets','two-column','kpi-cards','chart','image','quote','grid-cards'] as const).map(l => (
              <div key={l} className="px-2 py-1 rounded hover:bg-white/10 cursor-pointer" onClick={() => addSlide(l)}>{l}</div>
            ))}
          </div>
        </div>
        <div className="flex items-center gap-1">
          <button onClick={ex.exportPPTX} className="px-3 py-1 rounded bg-white/10 hover:bg-white/15">Export PPTX</button>
          <button onClick={ex.exportPDF} className="px-3 py-1 rounded bg-white/10 hover:bg-white/15">Export PDF</button>
          <button onClick={ex.exportDeck} className="px-3 py-1 rounded bg-white/10 hover:bg-white/15">Deck JSON</button>
        </div>
        <button className="px-3 py-1 rounded bg-white/10 hover:bg-white/15">Present</button>
        <button onClick={undo} className="px-2 py-1 rounded bg-white/10 hover:bg-white/15">Undo</button>
        <button className="px-2 py-1 rounded bg-white/10 hover:bg-white/15">Redo</button>
      </div>
    </div>
  )
}


