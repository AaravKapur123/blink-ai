import PptxGenJS from 'pptxgenjs'
import { DeckT } from '../state/store'

export async function exportDeckToPPTX(deck: DeckT) {
  const pptx = new PptxGenJS()
  pptx.layout = 'LAYOUT_16x9'
  for (const slide of deck.slides) {
    const s = pptx.addSlide()
    if (slide.title) {
      s.addText(slide.title, { x: 0.5, y: 0.3, w: 9, h: 0.7, fontSize: 28, bold: true, color: 'E8F0FF' })
    }
    for (const b of slide.blocks) {
      const frame = { x: b.frame.x / 100, y: b.frame.y / 100, w: b.frame.w / 100, h: b.frame.h / 100 }
      switch (b.kind) {
        case 'text':
          s.addText([{ text: b.html.replace(/<[^>]+>/g, ''), options: { fontSize: 14, color: 'E8F0FF' } }], frame)
          break
        case 'bullet':
          s.addText(b.items.map(t => ({ text: t, options: { bullet: true, fontSize: 14, color: 'E8F0FF' } })), frame)
          break
        case 'kpi':
          s.addText(`${b.label}: ${b.value}${b.delta ? ` (${b.delta})` : ''}`, { ...frame, fontSize: 18, bold: true, color: 'E8F0FF' })
          break
        case 'quote':
          s.addText(`“${b.text}”${b.by ? ` — ${b.by}` : ''}`, { ...frame, fontSize: 16, italic: true, color: 'E8F0FF' })
          break
        case 'image':
          if (b.dataUrl) s.addImage({ data: b.dataUrl, ...frame })
          break
        case 'chart':
          const data = b.dataset.map(ds => ({ name: ds.name, labels: b.xLabels ?? [], values: ds.values })) as any
          const opts: any = { x: frame.x, y: frame.y, w: frame.w, h: frame.h, chartColors: ['3FE1B0', 'B18CFF', 'F5C56B', 'FF6B6B'] }
          if (b.chartType === 'bar') s.addChart(pptx.ChartType.bar, data, opts)
          if (b.chartType === 'line') s.addChart(pptx.ChartType.line, data, opts)
          if (b.chartType === 'pie') s.addChart(pptx.ChartType.pie, data, opts)
          break
      }
    }
  }
  const blob = await pptx.write('blob')
  const reader = new FileReader()
  return await new Promise<string>((resolve) => {
    reader.onload = () => {
      const base64 = (reader.result as string).split(',')[1]
      resolve(base64)
    }
    reader.readAsDataURL(blob)
  })
}


