//
//  FormattedAIText.swift
//  UsefulMacApp
//
//  Lightweight formatted text renderer for AI messages (Markdown + code fences)
//

import SwiftUI
import Foundation
import AppKit

// Lightweight cache to avoid rebuilding attributed strings on every render
final class AITextAttributedCache {
	static let shared = NSCache<NSString, NSAttributedString>()
}

struct FormattedAIText: View {
	let text: String
	let highlight: String?

	var body: some View {
		let key = cacheKey(text: text, highlight: highlight)
		let ns = cachedDisplayNSAttributedString(key: key)
		let swiftAttr = AttributedString(ns)
		return Text(swiftAttr)
			.textSelection(.enabled)
			.lineSpacing(3)
			.tint(Color.primary)
	}



	private struct Segment {
		let _id = UUID()
		let content: String
		let isCodeBlock: Bool
		let language: String?
		
		init(content: String, isCodeBlock: Bool, language: String? = nil) {
			self.content = content
			self.isCodeBlock = isCodeBlock
			self.language = language
		}
	}

	private func makeSegments() -> [Segment] {
		// Split on triple backticks to capture code blocks; odd indices are code
		let delimiter = "```"
		let parts = text.components(separatedBy: delimiter)
		guard parts.count > 1 else {
			return [Segment(content: text, isCodeBlock: false)]
		}
		var segments: [Segment] = []
		for (idx, part) in parts.enumerated() {
			let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.isEmpty { continue }
			let isCode = idx % 2 == 1
			
			if isCode {
				// Extract language from first line
				let lines = trimmed.components(separatedBy: .newlines)
				let firstLine = lines.first ?? ""
				let languagePattern = "^[a-zA-Z][a-zA-Z0-9]*$"
				
				if firstLine.range(of: languagePattern, options: .regularExpression) != nil && firstLine.count < 20 {
					// First line is likely a language identifier
					let language = firstLine
					let codeContent = lines.dropFirst().joined(separator: "\n")
					segments.append(Segment(content: codeContent, isCodeBlock: true, language: language))
				} else {
					segments.append(Segment(content: trimmed, isCodeBlock: true, language: nil))
				}
			} else {
				segments.append(Segment(content: trimmed, isCodeBlock: false))
			}
		}
		return segments
	}

	private func buildAttributedString(from raw: String, highlight: String?) -> AttributedString {
		let segments = makeSegments()
		let result = NSMutableAttributedString()
		let bodyFont = NSFont.systemFont(ofSize: 15, weight: .light)
		let h1 = NSFont.systemFont(ofSize: 34, weight: .light)
		let h2 = NSFont.systemFont(ofSize: 28, weight: .light)
		let h3 = NSFont.systemFont(ofSize: 22, weight: .light)
		let h4 = NSFont.systemFont(ofSize: 18, weight: .medium)
		let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
		let blockquoteFont = NSFont.systemFont(ofSize: 15, weight: .light)

		for (segIndex, seg) in segments.enumerated() {
			if seg.isCodeBlock {
				// Enhanced code block rendering with language support
				let codeBlockString = renderCodeBlock(content: seg.content, language: seg.language, font: mono)
				result.append(codeBlockString)
			} else {
				let lines = seg.content.components(separatedBy: .newlines)
				var i = 0
				while i < lines.count {
					let rawLine = lines[i]
					let line = rawLine.trimmingCharacters(in: .whitespaces)
					if line.isEmpty {
						result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
						i += 1
						continue
					}
					// Detect GitHub-style markdown table blocks starting at this line
					if looksLikeTableStart(line: line) {
						print("🔍 Table detected at line \(i): '\(line)'")
						if let (tableAttr, nextIndex) = renderTableBlock(from: lines, start: i, mono: mono) {
							print("✅ Table rendered successfully")
							result.append(tableAttr)
							i = nextIndex
							continue
						} else {
							print("❌ Table rendering failed")
						}
					}

					// Handle horizontal rules
					if line.trimmingCharacters(in: .whitespaces) == "---" || line.trimmingCharacters(in: .whitespaces).hasPrefix("---") {
						let ruleAttr: [NSAttributedString.Key: Any] = [
							.font: bodyFont,
							.foregroundColor: NSColor.secondaryLabelColor
						]
						result.append(NSAttributedString(string: "————————————————————————————————\n", attributes: ruleAttr))
						i += 1
						continue
					}
					
					// Handle blockquotes
					if line.hasPrefix("> ") {
						let quoteText = String(line.dropFirst(2))
						let quoteAttr: [NSAttributedString.Key: Any] = [
							.font: blockquoteFont,
							.foregroundColor: NSColor.secondaryLabelColor,
							.backgroundColor: NSColor.controlBackgroundColor.withAlphaComponent(0.5)
						]
						result.append(NSAttributedString(string: "▌ ", attributes: [
							.font: bodyFont,
							.foregroundColor: NSColor.systemBlue
						]))
						if let md = try? AttributedString(markdown: quoteText) {
							let quoteMd = thinMarkdown(md)
							let mutableQuote = NSMutableAttributedString(attributedString: quoteMd)
							mutableQuote.addAttributes(quoteAttr, range: NSRange(location: 0, length: mutableQuote.length))
							result.append(mutableQuote)
						} else {
							result.append(NSAttributedString(string: quoteText, attributes: quoteAttr))
						}
						result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
						i += 1
						continue
					}

					var font = bodyFont
					var text = line
					if line.hasPrefix("# ") { font = h1; text = String(line.dropFirst(2)) }
					else if line.hasPrefix("## ") { font = h2; text = String(line.dropFirst(3)) }
					else if line.hasPrefix("### ") { font = h3; text = String(line.dropFirst(4)) }
					else if line.hasPrefix("#### ") { font = h4; text = String(line.dropFirst(5)) }
					else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") || line.range(of: "^\\d+\\. ", options: .regularExpression) != nil {
						// Bullet or numbered line
						let rest: String = {
							if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
								return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
							} else if let range = line.range(of: "^\\d+\\. ", options: .regularExpression) {
								return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
							}
							return line
						}()
						result.append(NSAttributedString(string: "• ", attributes: [.font: bodyFont]))
						if let md = try? AttributedString(markdown: rest) {
							result.append(thinMarkdown(md))
							result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
						} else {
							result.append(NSAttributedString(string: rest + "\n", attributes: [.font: bodyFont]))
						}
						i += 1
						continue
					}

					// Normal paragraph or heading body: keep markdown inline
					if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") || line.hasPrefix("#### ") {
						result.append(NSAttributedString(string: text + "\n", attributes: [.font: font]))
					} else if let md = try? AttributedString(markdown: text) {
						result.append(thinMarkdown(md))
						result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
					} else {
						result.append(NSAttributedString(string: text + "\n", attributes: [.font: bodyFont]))
					}
					i += 1
				}
			}
			if segIndex < segments.count - 1 {
				result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
			}
		}

		// First: replace complete markdown links [label](url) with clickable label only
		applyMarkdownLinks(into: result)

		// Numeric citation pass: map inline (domain.com, other.com) to [1][2] using the Sources block
		replaceInlineDomainsWithNumericCitations(in: result)
		
		// Second: during streaming, hide any trailing, incomplete markdown link URLs after "](http"
		hideIncompleteMarkdownTail(in: result)

		// Style all existing links (from markdown) as non-bold and underlined
		styleAllLinks(in: result)
		
		// Finally, linkify bare URLs with non-bold underlined styling.
		let full = result.string
		if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
			let sourcesRanges = findSourcesBlocks(in: full)
			detector.enumerateMatches(in: full, options: [], range: NSRange(location: 0, length: (full as NSString).length)) { match, _, _ in
				guard let m = match, let url = m.url else { return }
				result.addAttribute(.link, value: url, range: m.range)
				// Determine if link is within a Sources block
				let isInSourcesBlock = sourcesRanges.contains { sourcesRange in
					NSLocationInRange(m.range.location, sourcesRange) && NSLocationInRange(NSMaxRange(m.range) - 1, sourcesRange)
				}
				// Apply consistent non-bold underlined styling for all links
				let linkFont = NSFont.systemFont(ofSize: 11, weight: .regular)
				result.addAttribute(.font, value: linkFont, range: m.range)
				result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
			}
		}

		// Emphasize links inside a Sources: block
		emphasizeSourceLinks(in: result)
		// Apply highlight if requested (case-insensitive)
		if let qRaw = highlight?.trimmingCharacters(in: .whitespacesAndNewlines), !qRaw.isEmpty {
			let q = qRaw.lowercased()
			let nsFull = full as NSString
			var searchRange = NSRange(location: 0, length: nsFull.length)
			while true {
				let found = nsFull.range(of: q, options: [.caseInsensitive], range: searchRange)
				if found.location == NSNotFound { break }
				result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: found)
				let nextLocation = found.location + found.length
				if nextLocation >= nsFull.length { break }
				searchRange = NSRange(location: nextLocation, length: nsFull.length - nextLocation)
			}
		}
		return AttributedString(result)
	}

	// Replace inline bare-domain parentheses with numeric citations based on the Sources block
	private func replaceInlineDomainsWithNumericCitations(in mutable: NSMutableAttributedString) {
		let fullText = mutable.string
		let nsFull = fullText as NSString
		// Build ordered host -> index map from first Sources block
		guard let sourcesRange = findSourcesBlocks(in: fullText).first else { return }
		let sourcesText = nsFull.substring(with: sourcesRange)
		var hostOrder: [String] = []
		if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
			let matches = detector.matches(in: sourcesText, options: [], range: NSRange(location: 0, length: (sourcesText as NSString).length))
			for m in matches {
				guard let url = m.url, (url.scheme == "http" || url.scheme == "https") else { continue }
				let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
				if !host.isEmpty && !hostOrder.contains(host) { hostOrder.append(host) }
			}
		}
		guard !hostOrder.isEmpty else { return }
		var hostToIndex: [String: Int] = [:]
		for (i, h) in hostOrder.enumerated() { hostToIndex[h] = i + 1 }

		// Regex for "(domain.tld, domain2.tld)" possibly with spaces
		let pattern = "\\(([A-Za-z0-9_.-]+\\.[A-Za-z]{2,}(?:\\s*,\\s*[A-Za-z0-9_.-]+\\.[A-Za-z]{2,})*)\\)"
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
		let matches = regex.matches(in: fullText, options: [], range: NSRange(location: 0, length: nsFull.length))
		var edited = mutable
		for m in matches.reversed() {
			let inside = nsFull.substring(with: m.range(at: 1))
			let domains = inside.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "www.", with: "") }
			let indices = domains.compactMap { hostToIndex[$0] }
			let replacement = indices.isEmpty ? "" : indices.map { "[\($0)]" }.joined()
			edited.replaceCharacters(in: m.range, with: replacement)
		}
	}

	// Helper function to find all Sources: blocks in the text
	private func findSourcesBlocks(in text: String) -> [NSRange] {
		let ns = text as NSString
		var ranges: [NSRange] = []
		let pattern = #"(?m)^Sources?:\s*$"#
		
		guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return ranges }
		let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
		
		for match in matches {
			let startOfBlock = match.range.location
			let endOfText = ns.length
			let blockRange = NSRange(location: startOfBlock, length: endOfText - startOfBlock)
			ranges.append(blockRange)
		}
		
		return ranges
	}
	
	// Apply non-bold, underlined styling to all existing links (except those in Sources sections)
	private func styleAllLinks(in mutable: NSMutableAttributedString) {
		let fullRange = NSRange(location: 0, length: mutable.length)
		let linkFont = NSFont.systemFont(ofSize: 12, weight: .regular)
		let _ = mutable.string as NSString
		
		// Find all Sources: blocks to exclude from capsule styling
		let sourcesRanges = findSourcesBlocks(in: mutable.string)
		
		mutable.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
			if value != nil {
				// Check if this link is within a Sources block
				let isInSourcesBlock = sourcesRanges.contains { sourcesRange in
					NSLocationInRange(range.location, sourcesRange) && NSLocationInRange(NSMaxRange(range) - 1, sourcesRange)
				}
				
				// Apply simple underline + regular font outside Sources blocks
				if !isInSourcesBlock {
					mutable.addAttributes([
						.font: linkFont,
						.underlineStyle: NSUnderlineStyle.single.rawValue
					], range: range)
				}
			}
		}
	}
	
	// Replace [label](url) with attributed clickable label
	private func applyMarkdownLinks(into mutable: NSMutableAttributedString) {
		let s = mutable.string as NSString
		let pattern = #"\[([^\]]+)\]\((https?:[^)\s]+)\)"#
		guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
		let matches = regex.matches(in: mutable.string, options: [], range: NSRange(location: 0, length: s.length))
		for m in matches.reversed() {
			guard m.numberOfRanges >= 3 else { continue }
			let label = s.substring(with: m.range(at: 1))
			let urlStr = s.substring(with: m.range(at: 2))
			guard let url = URL(string: urlStr) else { continue }
			let linkFont = NSFont.systemFont(ofSize: 11, weight: .regular)
			let attrs: [NSAttributedString.Key: Any] = [
				.font: linkFont,
				.underlineStyle: NSUnderlineStyle.single.rawValue,
				.link: url
			]
			let replacement = NSAttributedString(string: label, attributes: attrs)
			mutable.replaceCharacters(in: m.range, with: replacement)
		}
	}

	// Hide partially streamed markdown link tails; keep the label visible
	private func hideIncompleteMarkdownTail(in mutable: NSMutableAttributedString) {
		let text = mutable.string
		// Capture label inside [] and the entire incomplete pattern
		let pattern = #"\[([^\]]+)\]\(https?://[^\s\)]*$"#
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
		let ns = text as NSString
		let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
		for m in matches.reversed() {
			if m.numberOfRanges >= 2 {
				let label = ns.substring(with: m.range(at: 1))
				mutable.replaceCharacters(in: m.range, with: label)
			}
		}
	}

	// Make links in a Sources: block readable (not bold), underlined, and accented
	private func emphasizeSourceLinks(in mutable: NSMutableAttributedString) {
		let whole = mutable.string
		let ns = whole as NSString
		// Match a line that is exactly 'Sources:' ignoring case
		guard let sourcesRegex = try? NSRegularExpression(pattern: "^\\s*Sources:\\s*$", options: [.anchorsMatchLines, .caseInsensitive]) else { return }
		let srcMatches = sourcesRegex.matches(in: whole, options: [], range: NSRange(location: 0, length: ns.length))
		for m in srcMatches.reversed() {
			// Light-weight header for 'Sources:' label
			mutable.removeAttribute(.font, range: m.range)
			mutable.addAttribute(.font, value: NSFont.systemFont(ofSize: 18, weight: .semibold), range: m.range)
			let start = m.range.location + m.range.length
			let tailRange = NSRange(location: start, length: ns.length - start)
			// Find next blank line or the end of the string
			let blankRegex = try? NSRegularExpression(pattern: "^\\s*$", options: [.anchorsMatchLines])
			let blank = blankRegex?.firstMatch(in: whole, options: [], range: tailRange)
			let end = blank?.range.location ?? ns.length
			let blockRange = NSRange(location: start, length: Swift.max(0, end - start))
			guard blockRange.length > 0 else { continue }

			let linkFont = NSFont.systemFont(ofSize: 15, weight: .regular)
			// First: style any ranges that already have a .link attribute (e.g., from markdown)
			var attributedLinkRanges: [NSRange] = []
			mutable.enumerateAttribute(.link, in: blockRange, options: []) { value, range, _ in
				if value != nil { attributedLinkRanges.append(range) }
			}
			for r in attributedLinkRanges.reversed() {
				// Remove capsule/bold styling from sources links
				mutable.removeAttribute(.backgroundColor, range: r)
				mutable.removeAttribute(.kern, range: r)
				mutable.removeAttribute(.baselineOffset, range: r)
				// Apply white underlined styling for sources section
				mutable.addAttributes([
					.font: linkFont,
					.foregroundColor: NSColor.white,
					.underlineStyle: NSUnderlineStyle.single.rawValue
				], range: r)
			}

			// Second: for any remaining bare URLs, detect and style
			if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
				let blockString = ns.substring(with: blockRange)
				let linkMatches = detector.matches(in: blockString, options: [], range: NSRange(location: 0, length: (blockString as NSString).length))
				for lm in linkMatches.reversed() {
					let absolute = NSRange(location: blockRange.location + lm.range.location, length: lm.range.length)
					guard let _ = lm.url else { continue }
					// Ensure clean, non-bold styling for Sources block
					mutable.removeAttribute(.backgroundColor, range: absolute)
					mutable.removeAttribute(.kern, range: absolute)
					mutable.removeAttribute(.baselineOffset, range: absolute)
					// Apply white underlined styling for sources section
					mutable.addAttributes([
						.font: linkFont,
						.foregroundColor: NSColor.white,
						.underlineStyle: NSUnderlineStyle.single.rawValue
					], range: absolute)
				}
			}
		}
	}

	// Render GitHub-style markdown table with enhanced formatting
	private func renderTableBlock(from lines: [String], start: Int, mono: NSFont) -> (NSAttributedString, Int)? {
		var rows: [[String]] = []
		var i = start
		while i < lines.count {
			let raw = lines[i]
			let line = raw.trimmingCharacters(in: .whitespaces)
			guard line.contains("|") else { break }
			
			// Handle both leading/trailing pipes and without
			let cleanLine = line.hasPrefix("|") ? String(line.dropFirst()) : line
			let finalLine = cleanLine.hasSuffix("|") ? String(cleanLine.dropLast()) : cleanLine
			
			let cells = finalLine.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
			rows.append(cells)
			i += 1
			// End when the next line is blank
			if i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty { break }
		}
		guard rows.count >= 1 else { 
			print("❌ Table failed: insufficient rows (\(rows.count))")
			return nil 
		}
		
		print("🔧 Table rendering: \(rows.count) rows")
		
		// If second row is a separator (---), drop it
		if rows.count > 1 && rows[1].allSatisfy({ $0.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").isEmpty }) {
			print("📋 Removing separator row")
			rows.remove(at: 1)
		}
		let colCount = rows.map { $0.count }.max() ?? 0
		guard colCount > 0 else { return nil }
		// Normalize columns
		for r in 0..<rows.count { if rows[r].count < colCount { rows[r] += Array(repeating: "", count: colCount - rows[r].count) } }
		// Compute widths with minimum padding
		var widths: [Int] = Array(repeating: 0, count: colCount)
		for r in rows { for (idx, cell) in r.enumerated() { widths[idx] = max(widths[idx], max(8, cell.count + 2)) } }
		func pad(_ s: String, _ w: Int) -> String { 
			let padding = max(0, w - s.count)
			return s + String(repeating: " ", count: padding)
		}
		
		let sb = NSMutableAttributedString()
		
		// Use a much simpler format that works reliably in SwiftUI
		for (ri, r) in rows.enumerated() {
			let isHeader = ri == 0
			
			if isHeader {
				// Add header with clear formatting
				var headerLine = ""
				for (ci, cell) in r.enumerated() {
					headerLine += cell.uppercased()
					if ci < r.count - 1 { headerLine += "   |   " }
				}
				
				let headerAttrs: [NSAttributedString.Key: Any] = [
					.font: NSFont.systemFont(ofSize: 15, weight: .bold),
					.foregroundColor: NSColor.systemBlue
				]
				sb.append(NSAttributedString(string: headerLine + "\n", attributes: headerAttrs))
				
				// Add clear separator line
				let separatorLength = headerLine.count
				let separator = String(repeating: "═", count: separatorLength)
				sb.append(NSAttributedString(string: separator + "\n", attributes: [.font: mono, .foregroundColor: NSColor.systemBlue]))
			} else {
				// Add data row with simple formatting
				var dataLine = ""
				for (ci, cell) in r.enumerated() {
					dataLine += cell
					if ci < r.count - 1 { dataLine += "   •   " }
				}
				
				let dataAttrs: [NSAttributedString.Key: Any] = [
					.font: NSFont.systemFont(ofSize: 13, weight: .medium),
					.foregroundColor: NSColor.labelColor
				]
				sb.append(NSAttributedString(string: dataLine + "\n", attributes: dataAttrs))
			}
		}
		
		// Add bottom line for clear table ending
		sb.append(NSAttributedString(string: "\n", attributes: [.font: mono]))
		return (sb, i)
	}

	private func looksLikeTableStart(line: String) -> Bool {
		// More robust table detection
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		
		// Must contain pipes
		guard trimmed.contains("|") else { return false }
		
		// Split by pipes and count non-empty cells
		let pieces = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
		let nonEmptyPieces = pieces.filter { !$0.isEmpty }
		
		// Need at least 2 non-empty cells
		let isTable = nonEmptyPieces.count >= 2
		if isTable {
			print("🔍 Table detected: '\(trimmed)' -> \(nonEmptyPieces.count) cells")
		}
		return isTable
	}

	private func thinMarkdown(_ md: AttributedString) -> NSAttributedString {
		let base = NSAttributedString(md)
		let ns = NSMutableAttributedString(attributedString: base)
		let full = NSRange(location: 0, length: ns.length)
		ns.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
			guard let font = value as? NSFont else { return }
			let size = font.pointSize
			let traits = font.fontDescriptor.symbolicTraits
			let isBold = traits.contains(.bold)
			let targetWeight: NSFont.Weight = isBold ? .semibold : .light
			let replacement = NSFont.systemFont(ofSize: size, weight: targetWeight)
			ns.removeAttribute(.font, range: range)
			ns.addAttribute(.font, value: replacement, range: range)
		}
		return ns
	}

	private func cacheKey(text: String, highlight: String?) -> String {
		let h = (highlight ?? "").lowercased()
		// Use a bounded prefix to keep keys small
		return "\(text.count)#\(h)#\(text.prefix(128))"
	}

	private func cachedAttributedString(key: String) -> AttributedString {
		if let ns = AITextAttributedCache.shared.object(forKey: key as NSString) {
			return AttributedString(ns)
		}
		let built = buildAttributedString(from: text, highlight: highlight)
		let nsBuilt = NSAttributedString(built)
		AITextAttributedCache.shared.setObject(nsBuilt, forKey: key as NSString)
		return built
	}

	private func cachedDisplayNSAttributedString(key: String) -> NSAttributedString {
		let displayKey = ("display#" + key) as NSString
		if let cached = AITextAttributedCache.shared.object(forKey: displayKey) {
			return cached
		}
		// Build base attributed content
		let base = buildAttributedString(from: text, highlight: highlight)
        let nsMutable = NSMutableAttributedString(attributedString: NSAttributedString(base))
		// Ensure Sources block emphasis persists
		emphasizeSourceLinks(in: nsMutable)
		AITextAttributedCache.shared.setObject(nsMutable, forKey: displayKey)
		return nsMutable
	}

	private func linkedAttributedString(_ string: String) -> AttributedString {
		let mutable = NSMutableAttributedString(string: string)
		if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
			let ns = string as NSString
			let range = NSRange(location: 0, length: ns.length)
			detector.enumerateMatches(in: string, options: [], range: range) { match, _, _ in
				guard let match = match, let url = match.url else { return }
				mutable.addAttribute(.link, value: url, range: match.range)
				// Apply capsule styling
				let linkFont = NSFont.systemFont(ofSize: 10, weight: .bold)
				mutable.addAttributes([
					.font: linkFont,
					.foregroundColor: NSColor.black,
					.backgroundColor: NSColor.systemGray.withAlphaComponent(0.8),
					.kern: 0.8,
					.baselineOffset: 0.8
				], range: match.range)
			}
		}
		return AttributedString(mutable)
	}

	// Enhanced code block renderer with language support and styling
	private func renderCodeBlock(content: String, language: String?, font: NSFont) -> NSAttributedString {
		let result = NSMutableAttributedString()
		
		// Add language header if present
		if let lang = language, !lang.isEmpty {
			let headerAttr: [NSAttributedString.Key: Any] = [
				.font: NSFont.systemFont(ofSize: 11, weight: .medium),
				.foregroundColor: NSColor.secondaryLabelColor,
				.backgroundColor: NSColor.controlBackgroundColor.withAlphaComponent(0.7)
			]
			result.append(NSAttributedString(string: " \(lang.uppercased()) ", attributes: headerAttr))
			result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
		}
		
		// Add code content with enhanced styling
		let codeAttr: [NSAttributedString.Key: Any] = [
			.font: font,
			.foregroundColor: NSColor.labelColor,
			.backgroundColor: NSColor.controlBackgroundColor.withAlphaComponent(0.4)
		]
		
		// Add subtle border effect by padding with background characters
		let paddedContent = content.components(separatedBy: .newlines)
			.map { "  \($0)  " }
			.joined(separator: "\n")
		
		result.append(NSAttributedString(string: paddedContent, attributes: codeAttr))
		result.append(NSAttributedString(string: "\n\n", attributes: [.font: font]))
		
		return result
	}

    @ViewBuilder
    private func renderRichMarkdown(_ content: String) -> some View { EmptyView() }
}

// Render NSAttributedString with clickable links and attachments using NSTextView
private struct AttributedTextView: NSViewRepresentable {
	let attributed: NSAttributedString

	func makeNSView(context: Context) -> NSScrollView {
		let scroll = NSScrollView()
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = false
		let textView = NSTextView()
		textView.drawsBackground = false
		textView.isEditable = false
		textView.isSelectable = true
		textView.textContainerInset = .zero
		textView.textContainer?.lineFragmentPadding = 0
		textView.linkTextAttributes = [
			.underlineStyle: NSUnderlineStyle.single.rawValue,
			.foregroundColor: NSColor.controlAccentColor
		]
		textView.textStorage?.setAttributedString(attributed)
		scroll.documentView = textView
		return scroll
	}

	func updateNSView(_ nsView: NSScrollView, context: Context) {
		(nsView.documentView as? NSTextView)?.textStorage?.setAttributedString(attributed)
	}
}




