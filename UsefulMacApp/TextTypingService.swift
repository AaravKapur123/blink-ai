//
//  TextTypingService.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import Foundation
import ApplicationServices
import AppKit
import Carbon

class TextTypingService {
    static let shared = TextTypingService()
    
    private init() {}
    // Multiplier to slow down student typing globally (adjusted for 50 WPM)
    private let studentDelayMultiplier: Double = 2.0
    
    // Thread-safe stop flag for session control
    private let stopQueue = DispatchQueue(label: "typing.stop.flag", attributes: .concurrent)
    private var _stopRequested: Bool = false
    private func setStop(_ value: Bool) {
        stopQueue.async(flags: .barrier) {
            self._stopRequested = value
        }
    }
    private func isStopRequested() -> Bool {
        var v = false
        stopQueue.sync { v = self._stopRequested }
        return v
    }
    func beginSession() { setStop(false) }
    func requestStop() { setStop(true) }
    
    func typeText(_ text: String) {
        // Small delay to ensure the system is ready
        usleep(100000) // 0.1 seconds
        
        // Type each character
        for character in text {
            typeCharacter(character)
            usleep(10000) // Small delay between characters
        }
    }

    func pasteText(_ text: String) {
        // Copy to clipboard and simulate Cmd+V for robust insertion
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        usleep(150000) // allow pasteboard to propagate

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    func typeTextHumanLike(_ text: String) {
        // Brief initial pause like a human settling before typing
        usleep(120000)
        var wordsSinceLastTypo = 0
        var nextTypoAtWord = Int.random(in: 5...12)
        var currentWordChars = 0
        // Natural short pauses should happen mainly after words/sentences
        let isLongText = text.count >= 250
        var wordsSinceBreak = 0
        var nextBreakAfterWords = Int.random(in: 8...20)
        for character in text {
            let isLetter = character.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            // Targeting 50 WPM (approximately 240ms per character average)
            let baseDelay = Double.random(in: 0.06...0.10) * studentDelayMultiplier
            // Space creates a slightly longer pause and advances word counters
            if character == " " {
                currentWordChars = 0
                wordsSinceLastTypo += 1
                let spacePause = Double.random(in: 0.04...0.12) * studentDelayMultiplier
                usleep(useconds_t((baseDelay + spacePause) * 1_000_000))
                typeCharacter(character)
                // After a word boundary, optionally add a natural short pause for long texts
                if isLongText {
                    wordsSinceBreak += 1
                    if wordsSinceBreak >= nextBreakAfterWords {
                        usleep(useconds_t(Double.random(in: 0.4...1.0) * studentDelayMultiplier * 1_000_000))
                        wordsSinceBreak = 0
                        nextBreakAfterWords = Int.random(in: 8...20)
                    }
                }
                continue
            }
            // Sentence-ending punctuation pauses more
            if [".", "?", "!"].contains(String(character)) {
                let sentencePause = Double.random(in: 0.45...0.90) * studentDelayMultiplier
                usleep(useconds_t((baseDelay + sentencePause) * 1_000_000))
                typeCharacter(character)
                // After sentence end, optional thinking pause and reset the word-break counter
                if isLongText {
                    usleep(useconds_t(Double.random(in: 0.5...1.2) * studentDelayMultiplier * 1_000_000))
                    wordsSinceBreak = 0
                    nextBreakAfterWords = Int.random(in: 8...20)
                }
                continue
            }
            // Occasionally make a small typo and correct it for realism
            let shouldTypo = wordsSinceLastTypo >= nextTypoAtWord && currentWordChars >= 2 && isLetter
            if shouldTypo {
                let wrongChar = randomNearbyKey(for: character)
                typeCharacter(wrongChar)
                usleep(useconds_t(Double.random(in: 0.08...0.22) * studentDelayMultiplier * 1_000_000))
                pressBackspace(times: 1)
                usleep(useconds_t(Double.random(in: 0.04...0.12) * studentDelayMultiplier * 1_000_000))
                typeCharacter(character)
                wordsSinceLastTypo = 0
                nextTypoAtWord = Int.random(in: 5...12)
            } else {
                usleep(useconds_t(baseDelay * 1_000_000))
                typeCharacter(character)
                currentWordChars += 1
            }
        }
    }
    
    // Session-based variant that supports pausing via internal stop flag.
    // Returns the next index to type (i.e., where it paused or text.count if finished)
    func typeTextHumanLikeSession(_ text: String, startAt: Int, allowTypos: Bool = false) async -> Int {
        var index = max(0, min(startAt, text.count))
        var wordsSinceLastTypo = 0
        // Slightly more frequent typos (~1.25x)
        var nextTypoAtWord = allowTypos ? Int.random(in: 6...10) : Int.max
        var currentWordChars = 0
        // Small initial pause
        try? await Task.sleep(nanoseconds: 100_000_000)
        let isLongText = text.count >= 250
        var wordsSinceBreak = 0
        var nextBreakAfterWords = Int.random(in: 8...20)
        while index < text.count {
            if isStopRequested() { break }
            let character = text[text.index(text.startIndex, offsetBy: index)]
            let isLetter = character.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            let baseDelay = Double.random(in: 0.06...0.10) * studentDelayMultiplier
            if character == " " {
                currentWordChars = 0
                wordsSinceLastTypo += 1
                let spacePause = Double.random(in: 0.04...0.12) * studentDelayMultiplier
                try? await Task.sleep(nanoseconds: UInt64((baseDelay + spacePause) * 1_000_000_000))
                typeCharacter(character)
                index += 1
                if isLongText {
                    wordsSinceBreak += 1
                    if wordsSinceBreak >= nextBreakAfterWords {
                        if isStopRequested() { break }
                        try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.4...1.0) * studentDelayMultiplier * 1_000_000_000))
                        wordsSinceBreak = 0
                        nextBreakAfterWords = Int.random(in: 8...20)
                    }
                }
                continue
            }
            if [".", "?", "!"].contains(String(character)) {
                let sentencePause = Double.random(in: 0.45...0.90) * studentDelayMultiplier
                try? await Task.sleep(nanoseconds: UInt64((baseDelay + sentencePause) * 1_000_000_000))
                typeCharacter(character)
                index += 1
                if isLongText {
                    if isStopRequested() { break }
                    try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.5...1.2) * studentDelayMultiplier * 1_000_000_000))
                    wordsSinceBreak = 0
                    nextBreakAfterWords = Int.random(in: 8...20)
                }
                continue
            }
            let shouldTypo = allowTypos && wordsSinceLastTypo >= nextTypoAtWord && currentWordChars >= 2 && isLetter
            if shouldTypo {
                let wrongChar = randomNearbyKey(for: character)
                typeCharacter(wrongChar)
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.08...0.22) * studentDelayMultiplier * 1_000_000_000))
                pressBackspace(times: 1)
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.04...0.12) * studentDelayMultiplier * 1_000_000_000))
                typeCharacter(character)
                wordsSinceLastTypo = 0
                nextTypoAtWord = allowTypos ? Int.random(in: 6...10) : Int.max
                currentWordChars += 1
                index += 1
            } else {
                try? await Task.sleep(nanoseconds: UInt64(baseDelay * 1_000_000_000))
                typeCharacter(character)
                currentWordChars += 1
                index += 1
            }
        }
        return index
    }
    
    private func typeCharacter(_ character: Character) {
        _ = String(character)
        
        // Handle special characters
        if character == "\n" {
            pressKey(keyCode: CGKeyCode(kVK_Return))
            return
        }
        
        if character == "\t" {
            pressKey(keyCode: CGKeyCode(kVK_Tab))
            return
        }
        
        // Prefer Unicode input to avoid layout/caps/shift issues
        typeUnicodeCharacter(character)
    }
    
    private func pressKey(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        
        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }
    
    private func pressBackspace(times: Int) {
        guard times > 0 else { return }
        for _ in 0..<times {
            pressKey(keyCode: CGKeyCode(kVK_Delete))
            usleep(40000)
        }
    }
    
    private func typeUnicodeCharacter(_ character: Character) {
        // Use UTF-16 units for multi-scalar characters (emojis, accents). Fall back to single scalar.
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16Units = Array(String(character).utf16)
        if utf16Units.isEmpty {
            return
        }
        let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        keyDownEvent?.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
        keyUpEvent?.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: utf16Units)
        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }
    
    private func getKeyCode(for character: Character) -> (keyCode: CGKeyCode, shiftRequired: Bool)? {
        let keyMap: [Character: (CGKeyCode, Bool)] = [
            "a": (CGKeyCode(kVK_ANSI_A), false), "A": (CGKeyCode(kVK_ANSI_A), true),
            "b": (CGKeyCode(kVK_ANSI_B), false), "B": (CGKeyCode(kVK_ANSI_B), true),
            "c": (CGKeyCode(kVK_ANSI_C), false), "C": (CGKeyCode(kVK_ANSI_C), true),
            "d": (CGKeyCode(kVK_ANSI_D), false), "D": (CGKeyCode(kVK_ANSI_D), true),
            "e": (CGKeyCode(kVK_ANSI_E), false), "E": (CGKeyCode(kVK_ANSI_E), true),
            "f": (CGKeyCode(kVK_ANSI_F), false), "F": (CGKeyCode(kVK_ANSI_F), true),
            "g": (CGKeyCode(kVK_ANSI_G), false), "G": (CGKeyCode(kVK_ANSI_G), true),
            "h": (CGKeyCode(kVK_ANSI_H), false), "H": (CGKeyCode(kVK_ANSI_H), true),
            "i": (CGKeyCode(kVK_ANSI_I), false), "I": (CGKeyCode(kVK_ANSI_I), true),
            "j": (CGKeyCode(kVK_ANSI_J), false), "J": (CGKeyCode(kVK_ANSI_J), true),
            "k": (CGKeyCode(kVK_ANSI_K), false), "K": (CGKeyCode(kVK_ANSI_K), true),
            "l": (CGKeyCode(kVK_ANSI_L), false), "L": (CGKeyCode(kVK_ANSI_L), true),
            "m": (CGKeyCode(kVK_ANSI_M), false), "M": (CGKeyCode(kVK_ANSI_M), true),
            "n": (CGKeyCode(kVK_ANSI_N), false), "N": (CGKeyCode(kVK_ANSI_N), true),
            "o": (CGKeyCode(kVK_ANSI_O), false), "O": (CGKeyCode(kVK_ANSI_O), true),
            "p": (CGKeyCode(kVK_ANSI_P), false), "P": (CGKeyCode(kVK_ANSI_P), true),
            "q": (CGKeyCode(kVK_ANSI_Q), false), "Q": (CGKeyCode(kVK_ANSI_Q), true),
            "r": (CGKeyCode(kVK_ANSI_R), false), "R": (CGKeyCode(kVK_ANSI_R), true),
            "s": (CGKeyCode(kVK_ANSI_S), false), "S": (CGKeyCode(kVK_ANSI_S), true),
            "t": (CGKeyCode(kVK_ANSI_T), false), "T": (CGKeyCode(kVK_ANSI_T), true),
            "u": (CGKeyCode(kVK_ANSI_U), false), "U": (CGKeyCode(kVK_ANSI_U), true),
            "v": (CGKeyCode(kVK_ANSI_V), false), "V": (CGKeyCode(kVK_ANSI_V), true),
            "w": (CGKeyCode(kVK_ANSI_W), false), "W": (CGKeyCode(kVK_ANSI_W), true),
            "x": (CGKeyCode(kVK_ANSI_X), false), "X": (CGKeyCode(kVK_ANSI_X), true),
            "y": (CGKeyCode(kVK_ANSI_Y), false), "Y": (CGKeyCode(kVK_ANSI_Y), true),
            "z": (CGKeyCode(kVK_ANSI_Z), false), "Z": (CGKeyCode(kVK_ANSI_Z), true),
            "1": (CGKeyCode(kVK_ANSI_1), false), "!": (CGKeyCode(kVK_ANSI_1), true),
            "2": (CGKeyCode(kVK_ANSI_2), false), "@": (CGKeyCode(kVK_ANSI_2), true),
            "3": (CGKeyCode(kVK_ANSI_3), false), "#": (CGKeyCode(kVK_ANSI_3), true),
            "4": (CGKeyCode(kVK_ANSI_4), false), "$": (CGKeyCode(kVK_ANSI_4), true),
            "5": (CGKeyCode(kVK_ANSI_5), false), "%": (CGKeyCode(kVK_ANSI_5), true),
            "6": (CGKeyCode(kVK_ANSI_6), false), "^": (CGKeyCode(kVK_ANSI_6), true),
            "7": (CGKeyCode(kVK_ANSI_7), false), "&": (CGKeyCode(kVK_ANSI_7), true),
            "8": (CGKeyCode(kVK_ANSI_8), false), "*": (CGKeyCode(kVK_ANSI_8), true),
            "9": (CGKeyCode(kVK_ANSI_9), false), "(": (CGKeyCode(kVK_ANSI_9), true),
            "0": (CGKeyCode(kVK_ANSI_0), false), ")": (CGKeyCode(kVK_ANSI_0), true),
            " ": (CGKeyCode(kVK_Space), false),
            ".": (CGKeyCode(kVK_ANSI_Period), false), ">": (CGKeyCode(kVK_ANSI_Period), true),
            ",": (CGKeyCode(kVK_ANSI_Comma), false), "<": (CGKeyCode(kVK_ANSI_Comma), true),
            ";": (CGKeyCode(kVK_ANSI_Semicolon), false), ":": (CGKeyCode(kVK_ANSI_Semicolon), true),
            "'": (CGKeyCode(kVK_ANSI_Quote), false), "\"": (CGKeyCode(kVK_ANSI_Quote), true),
            "/": (CGKeyCode(kVK_ANSI_Slash), false), "?": (CGKeyCode(kVK_ANSI_Slash), true),
            "\\": (CGKeyCode(kVK_ANSI_Backslash), false), "|": (CGKeyCode(kVK_ANSI_Backslash), true),
            "`": (CGKeyCode(kVK_ANSI_Grave), false), "~": (CGKeyCode(kVK_ANSI_Grave), true),
            "-": (CGKeyCode(kVK_ANSI_Minus), false), "_": (CGKeyCode(kVK_ANSI_Minus), true),
            "=": (CGKeyCode(kVK_ANSI_Equal), false), "+": (CGKeyCode(kVK_ANSI_Equal), true),
            "[": (CGKeyCode(kVK_ANSI_LeftBracket), false), "{": (CGKeyCode(kVK_ANSI_LeftBracket), true),
            "]": (CGKeyCode(kVK_ANSI_RightBracket), false), "}": (CGKeyCode(kVK_ANSI_RightBracket), true)
        ]
        
        return keyMap[character]
    }
    
    private func randomNearbyKey(for character: Character) -> Character {
        let lower = Character(String(character).lowercased())
        let neighbors: [Character: [String]] = [
            "a": ["q","w","s","z"],
            "s": ["w","e","d","x","a"],
            "d": ["e","r","f","c","s"],
            "f": ["r","t","g","v","d"],
            "g": ["t","y","h","b","f"],
            "h": ["y","u","j","n","g"],
            "j": ["u","i","k","m","h"],
            "k": ["i","o","l","j"],
            "l": ["o","p","k"],
            "q": ["w","a"],
            "w": ["q","e","s"],
            "e": ["w","r","d"],
            "r": ["e","t","f"],
            "t": ["r","y","g"],
            "y": ["t","u","h"],
            "u": ["y","i","j"],
            "i": ["u","o","k"],
            "o": ["i","p","l"],
            "p": ["o","[",";"],
            "z": ["a","s","x"],
            "x": ["z","s","d","c"],
            "c": ["x","d","f","v"],
            "v": ["c","f","g","b"],
            "b": ["v","g","h","n"],
            "n": ["b","h","j","m"],
            "m": ["n","j","k"]
        ]
        if let options = neighbors[lower], let pick = options.randomElement() {
            return Character(pick)
        }
        return lower
    }
}
