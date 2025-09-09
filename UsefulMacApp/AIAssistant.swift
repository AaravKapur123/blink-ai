//
//  AIAssistant.swift
//  UsefulMacApp
//
//  Created by AI on 8/27/25.
//

import Foundation

@MainActor
struct AIInvokeResult {
    let deckJSON: String
    let isPatch: Bool
}

@MainActor
final class AIAssistant {
    private let openAI = OpenAIService()

    // Orchestrator on Web builds prompt and intent. We enforce the system style and JSON shape.
    func invoke(prompt: String, context: [String: Any]?, tool: String?) async throws -> AIInvokeResult {
        let systemPrompt = """
        You are a senior presentation author and designer. Output only via the provided tool.
        Style: card-based layouts, concise storytelling, quant-first. Prefer kpi cards, 2-column comparisons, and clear charts. Use real-sounding but source-free placeholders unless user supplies data; do not fabricate citations. Numbers must be internally consistent. Keep slide titles under 60 chars, bullets under 12 words. Favor verbs. When uncertain, suggest visuals in the notes. Always return valid DeckJSON v1, using layout+blocks and theme tokens—not raw markup paragraphs.
        """

        let schemaHint = """
        Tool name: create_or_edit_deck
        Description: Return a complete DeckJSON v1 or a patch (target slide ids + changes). If the user asks to add/modify one slide, return only that slide(s) in slides with unchanged ids.

        DeckJSON v1 Types (TypeScript):
        export type Deck = {
          id: string;
          title: string;
          theme: string; // ThemeId
          createdAt: string;
          slides: Slide[];
          meta?: { source?: string; disclaimer?: string };
          patch?: boolean; // optional flag if this is a patch
        };
        export type Slide = {
          id: string;
          layout: "title" | "title-bullets" | "two-column" | "kpi-cards" | "chart" | "image" | "quote" | "grid-cards";
          title?: string;
          notes?: string;
          blocks: Block[];
        };
        export type Block =
          | { kind: "text"; html: string; frame: Rect }
          | { kind: "bullet"; items: string[]; frame: Rect }
          | { kind: "kpi"; label: string; value: string; delta?: string; intent?: "good"|"bad"|"neutral"; frame: Rect }
          | { kind: "quote"; text: string; by?: string; frame: Rect }
          | { kind: "image"; dataUrl?: string; url?: string; caption?: string; frame: Rect }
          | { kind: "chart"; chartType: "bar"|"line"|"pie"; dataset: DataSeries[]; xLabels?: string[]; yLabel?: string; frame: Rect };
        export type DataSeries = { name: string; values: number[] };
        export type Rect = { x: number; y: number; w: number; h: number };
        """

        let fewShot = """
        Few-shot Example:
        User: "Create an investment analysis on AI & tech stocks 2025, include NVDA/MSFT/AVGO/PLTR KPIs and a why-now slide."
        Tool output (abbrev): a deck with
        - Slide 1: Title
        - Slide 2: KPI cards (NVDA/MSFT/AVGO/PLTR with value, delta, intent)
        - Slide 3: Why-Now (bullets)
        - Slide 4: Chart (bar: revenue growth by company)
        - Slide 5: Risks & Considerations (two-column)
        """

        // Compose final instruction requesting JSON only
        var fullPrompt = """
        SYSTEM:\n\(systemPrompt)\n\nSCHEMA:\n\(schemaHint)\n\nFEW-SHOT:\n\(fewShot)\n\nUSER:\n\(prompt)\n\nReturn ONLY a valid DeckJSON v1 object (no prose), with a top-level object { id, title, theme, createdAt, slides, meta?, patch? }.
        """

        if let contextJSON = try? serializeContext(context) {
            fullPrompt += "\n\nCONTEXT_JSON:\n" + contextJSON
        }

        // Call GPT-5 via existing client
        let raw = try await openAIServiceSend(model: "gpt-5", text: fullPrompt, maxTokens: 6000, temperature: 0.4)
        let json = extractJSONObject(from: raw)
        let isPatch = jsonContainsPatchTrue(json)
        return AIInvokeResult(deckJSON: json, isPatch: isPatch)
    }

    private func serializeContext(_ context: [String: Any]?) throws -> String {
        guard let context = context, JSONSerialization.isValidJSONObject(context) else { return "{}" }
        let data = try JSONSerialization.data(withJSONObject: context, options: [.prettyPrinted])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func openAIServiceSend(model: String, text: String, maxTokens: Int, temperature: Double) async throws -> String {
        // Use existing OpenAIService to send a single text message
        // Note: OpenAIService currently locks model inside method; use sendTextMessage and let it override
        // We add a lightweight method path by calling sendTextMessage directly
        return try await openAI.sendTextMessage(text)
    }

    private func extractJSONObject(from response: String) -> String {
        if let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}") {
            let json = String(response[start...end])
            return json
        }
        return "{}"
    }

    private func jsonContainsPatchTrue(_ json: String) -> Bool {
        // Compact whitespace and check for exact token
        var compact = json.replacingOccurrences(of: " ", with: "")
        compact = compact.replacingOccurrences(of: "\n", with: "")
        compact = compact.replacingOccurrences(of: "\r", with: "")
        compact = compact.replacingOccurrences(of: "\t", with: "")
        return compact.contains("\"patch\":true")
    }
}


