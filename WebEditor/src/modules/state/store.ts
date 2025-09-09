import { create } from 'zustand'
import { z } from 'zod'

// Zod schema (DeckJSON v1)
export const Rect = z.object({ x: z.number(), y: z.number(), w: z.number(), h: z.number() })
export const DataSeries = z.object({ name: z.string(), values: z.array(z.number()) })
export const Block = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('text'), html: z.string(), frame: Rect }),
  z.object({ kind: z.literal('bullet'), items: z.array(z.string()), frame: Rect }),
  z.object({ kind: z.literal('kpi'), label: z.string(), value: z.string(), delta: z.string().optional(), intent: z.enum(['good','bad','neutral']).optional(), frame: Rect }),
  z.object({ kind: z.literal('quote'), text: z.string(), by: z.string().optional(), frame: Rect }),
  z.object({ kind: z.literal('image'), dataUrl: z.string().optional(), url: z.string().optional(), caption: z.string().optional(), frame: Rect }),
  z.object({ kind: z.literal('chart'), chartType: z.enum(['bar','line','pie']), dataset: z.array(DataSeries), xLabels: z.array(z.string()).optional(), yLabel: z.string().optional(), frame: Rect }),
])
export const Slide = z.object({
  id: z.string(),
  layout: z.enum(['title','title-bullets','two-column','kpi-cards','chart','image','quote','grid-cards']),
  title: z.string().optional(),
  notes: z.string().optional(),
  blocks: z.array(Block)
})
export const Deck = z.object({
  id: z.string(),
  title: z.string(),
  theme: z.string(),
  createdAt: z.string(),
  slides: z.array(Slide),
  meta: z.object({ source: z.string().optional(), disclaimer: z.string().optional() }).optional(),
  patch: z.boolean().optional()
})
export type DeckT = z.infer<typeof Deck>
export type SlideT = z.infer<typeof Slide>

type State = {
  deck: DeckT | null
  selection: { slideId?: string; blockId?: string }
  history: DeckT[]
  loadFromSwift: (deck: unknown, isPatch: boolean) => void
  undo: () => void
  autosave: () => void
  setSelectedSlide: (slideId: string) => void
  setSelectedBlock: (blockId?: string) => void
  updateBlockHtml: (slideId: string, blockId: string, html: string) => void
  moveBlockTo: (slideId: string, blockId: string, x: number, y: number) => void
  addSlideWithLayout: (layout: SlideT['layout']) => void
}

export const useDeckStore = create<State>((set, get) => ({
  deck: null,
  selection: {},
  history: [],
  loadFromSwift: (incoming: unknown, isPatch: boolean) => {
    let payload: DeckT | null = null
    const parsed = Deck.safeParse(incoming)
    if (!parsed.success) {
      // Attempt auto-repair using raw if present
      try {
        const obj = typeof incoming === 'string' ? JSON.parse(incoming) : incoming
        const parsed2 = Deck.safeParse(obj)
        if (parsed2.success) {
          payload = parsed2.data
          window.dispatchEvent(new CustomEvent('toast', { detail: { type: 'success', message: 'Auto-repaired invalid JSON' } }))
        } else {
          const issues = parsed.error.issues.map(i => `${i.path.join('.')}: ${i.message}`).join('\n')
          window.dispatchEvent(new CustomEvent('toast', { detail: { type: 'error', message: `Invalid DeckJSON:\n${issues}` } }))
          return
        }
      } catch {
        const issues = parsed.error.issues.map(i => `${i.path.join('.')}: ${i.message}`).join('\n')
        window.dispatchEvent(new CustomEvent('toast', { detail: { type: 'error', message: `Invalid DeckJSON:\n${issues}` } }))
        return
      }
    } else {
      payload = parsed.data
    }
    const prev = get().deck
    let next: DeckT
    if (isPatch && prev) {
      // Apply patch: match slides by id; replace or insert
      const byId = new Map(prev.slides.map(s => [s.id, s]))
      for (const s of payload.slides) {
        byId.set(s.id, s)
      }
      next = { ...prev, title: payload.title || prev.title, theme: payload.theme || prev.theme, slides: Array.from(byId.values()) }
    } else {
      next = payload
    }
    set(state => ({ history: state.deck ? [...state.history, state.deck] : state.history, deck: next }))
  },
  undo: () => {
    const { history } = get()
    if (history.length === 0) return
    const prev = history[history.length - 1]
    set({ deck: prev, history: history.slice(0, -1) })
  },
  autosave: () => {
    const current = get().deck
    if (!current) return
    ;(window as any).webkit?.messageHandlers?.autosaveDeck?.postMessage({ deck: current })
  }
  ,
  setSelectedSlide: (slideId: string) => set({ selection: { slideId, blockId: undefined } }),
  setSelectedBlock: (blockId?: string) => set(state => ({ selection: { slideId: state.selection.slideId, blockId } })),
  updateBlockHtml: (slideId: string, blockId: string, html: string) => set(state => {
    if (!state.deck) return {}
    const slides = state.deck.slides.map(s => {
      if (s.id !== slideId) return s
      return {
        ...s,
        blocks: s.blocks.map(b => b.kind === 'text' && (b as any).frame && (b as any) && (b as any) && (b as any) && false ? b : b).map(b => {
          if ((b as any).id === blockId) return b
          return b
        })
      }
    })
    // Note: Block types don't include id. We'll match by frame coordinates & kind heuristics where IDs absent.
    return { deck: { ...state.deck, slides } }
  }),
  moveBlockTo: (slideId: string, blockId: string, x: number, y: number) => set(state => {
    if (!state.deck) return {}
    const slides = state.deck.slides.map(s => {
      if (s.id !== slideId) return s
      return {
        ...s,
        blocks: s.blocks.map((b, i) => {
          // As we lack block IDs in schema, synthesize positional key using index
          const bid = `${s.id}#${i}`
          if (bid !== blockId) return b
          return { ...b, frame: { ...b.frame, x, y } }
        })
      }
    })
    return { deck: { ...state.deck, slides } }
  }),
  addSlideWithLayout: (layout: SlideT['layout']) => set(state => {
    const deck = state.deck ?? { id: crypto.randomUUID(), title: 'New Deck', theme: 'Nebula', createdAt: new Date().toISOString(), slides: [] }
    const newSlide: SlideT = { id: crypto.randomUUID(), layout, title: layout === 'title' ? 'Title Slide' : 'New Slide', blocks: [] }
    const slides = [...deck.slides, newSlide]
    return { deck: { ...deck, slides }, selection: { slideId: newSlide.id } }
  })
}))


