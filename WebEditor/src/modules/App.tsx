import React, { useEffect } from 'react'
import { Toolbar } from './ui/Toolbar'
import { Filmstrip } from './ui/Filmstrip'
import { Canvas } from './ui/Canvas'
import { AIRail } from './ui/AIRail'
import { useDeckStore } from './state/store'
import { ToastHost } from './ui/Toasts'

export const App: React.FC = () => {
  const loadFromSwift = useDeckStore(s => s.loadFromSwift)

  useEffect(() => {
    const onAIResult = (e: any) => {
      const detail = e.detail
      if (!detail) return
      loadFromSwift(detail.deck, Boolean(detail.patch))
    }
    const onLoadDeck = (e: any) => {
      const detail = e.detail
      if (detail?.deck) {
        loadFromSwift(detail.deck, false)
      }
    }
    window.addEventListener('aiResult' as any, onAIResult)
    window.addEventListener('loadDeckResult' as any, onLoadDeck)
    return () => {
      window.removeEventListener('aiResult' as any, onAIResult)
      window.removeEventListener('loadDeckResult' as any, onLoadDeck)
    }
  }, [loadFromSwift])

  return (
    <div className="h-full flex flex-col">
      <ToastHost />
      <Toolbar />
      <div className="flex flex-1 overflow-hidden">
        <Filmstrip />
        <Canvas />
        <AIRail />
      </div>
    </div>
  )
}


