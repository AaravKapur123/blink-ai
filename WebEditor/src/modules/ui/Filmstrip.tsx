import React from 'react'
import { useDeckStore } from '../state/store'

export const Filmstrip: React.FC = () => {
  const deck = useDeckStore(s => s.deck)
  const sel = useDeckStore(s => s.selection)
  const setSelectedSlide = useDeckStore(s => s.setSelectedSlide)
  return (
    <div className="w-48 border-r border-white/10 overflow-auto p-2 space-y-2">
      {(deck?.slides ?? []).map((s, idx) => (
        <div key={s.id} onClick={() => setSelectedSlide(s.id)} className={`card p-2 text-xs cursor-pointer ${sel.slideId === s.id ? 'ring-2 ring-mint' : ''}`}>
          <div className="opacity-70">{idx + 1}.</div>
          <div className="font-medium truncate">{s.title ?? 'Slide'}</div>
        </div>
      ))}
    </div>
  )
}


