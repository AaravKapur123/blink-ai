import { DeckT } from '../state/store'

function drawSlideToCanvas(slide: DeckT['slides'][number], theme: string) {
  const w = 1600, h = 900
  const canvas = document.createElement('canvas')
  canvas.width = w
  canvas.height = h
  const ctx = canvas.getContext('2d')!
  // Nebula gradient background by default
  const grad = ctx.createLinearGradient(0, 0, 0, h)
  grad.addColorStop(0, '#0B1422')
  grad.addColorStop(1, '#08111B')
  ctx.fillStyle = grad
  ctx.fillRect(0, 0, w, h)

  // Title
  if (slide.title) {
    ctx.fillStyle = '#E8F0FF'
    ctx.font = '700 56px Inter'
    ctx.fillText(slide.title, 80, 140)
  }
  // Basic block rendering placeholders
  ctx.fillStyle = 'rgba(255,255,255,0.05)'
  for (const b of slide.blocks) {
    ctx.fillRect(b.frame.x * 10, b.frame.y * 10, b.frame.w * 10, b.frame.h * 10)
  }

  return canvas.toDataURL('image/png')
}

export function renderSlidesToPNGs(deck: DeckT): string[] {
  const imgs: string[] = []
  for (const slide of deck.slides) {
    imgs.push(drawSlideToCanvas(slide, deck.theme))
  }
  return imgs
}


