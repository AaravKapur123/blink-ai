import { Deck } from '../state/store'

export type AIIntent = 'create' | 'add' | 'regenerate' | 'tighten' | 'chart' | 'edit'

export async function invokeAI(prompt: string, context?: any) {
  ;(window as any).ai?.invoke?.(prompt, context, 'create_or_edit_deck')
}

export function validateDeckJSON(obj: unknown) {
  const parsed = Deck.safeParse(obj)
  return parsed
}

export async function autoRepairJSON(broken: string) {
  // Ask the model to repair without changing content, structure only
  const repairPrompt = `Repair the following DeckJSON to be valid per schema. Output JSON only.\n\n${broken}`
  ;(window as any).ai?.invoke?.(repairPrompt, { intent: 'repair' }, 'create_or_edit_deck')
}


