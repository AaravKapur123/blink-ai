import React, { useState } from 'react'
import { useDeckStore } from '../state/store'

export const AIRail: React.FC = () => {
  const deck = useDeckStore(s => s.deck)
  const [prompt, setPrompt] = useState('')

  const planOrCreate = (kind: 'plan' | 'create') => {
    const p = `${kind === 'plan' ? 'Plan' : 'Create'} a deck: ${prompt}`
    ;(window as any).ai?.invoke?.(p, { deck }, 'create_or_edit_deck')
  }

  return (
    <div className="w-80 border-l border-white/10 p-3 space-y-3">
      <div className="text-sm opacity-70">AI Presentation Creator • GPT-5</div>
      <textarea
        className="w-full h-28 bg-white/5 rounded p-2 outline-none"
        placeholder="Plan deck, Create, Rewrite selection, Add chart"
        value={prompt}
        onChange={e => setPrompt(e.target.value)}
      />
      <div className="flex gap-2">
        <button onClick={() => planOrCreate('plan')} className="px-3 py-1 rounded bg-white/10 hover:bg-white/15">Plan</button>
        <button onClick={() => planOrCreate('create')} className="px-3 py-1 rounded bg-white/10 hover:bg-white/15">Create</button>
      </div>
      <div className="text-xs text-muted">Streaming responses will appear here.</div>
    </div>
  )
}


