import React, { useEffect, useState } from 'react'

type Toast = { id: string; type: 'info'|'error'|'success'; message: string }

export const ToastHost: React.FC = () => {
  const [toasts, setToasts] = useState<Toast[]>([])
  useEffect(() => {
    const handler = (e: any) => {
      const t = e.detail || { type: 'info', message: String(e.detail) }
      const toast: Toast = { id: Math.random().toString(36).slice(2), type: t.type || 'info', message: t.message }
      setToasts(prev => [...prev, toast])
      setTimeout(() => setToasts(prev => prev.filter(x => x.id !== toast.id)), 4000)
    }
    window.addEventListener('toast' as any, handler)
    return () => window.removeEventListener('toast' as any, handler)
  }, [])
  return (
    <div className="fixed bottom-4 right-4 space-y-2 z-50">
      {toasts.map(t => (
        <div key={t.id} className={`card px-3 py-2 text-sm ${t.type === 'error' ? 'border-red/50' : t.type === 'success' ? 'border-mint/50' : ''}`}>
          {t.message}
        </div>
      ))}
    </div>
  )
}


