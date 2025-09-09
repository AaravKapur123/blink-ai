//
//  ScreenshotService.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

class ScreenshotService: @unchecked Sendable {
    static let shared = ScreenshotService()
    
    private init() {}
    
    func captureScreen() async -> Data? {
        // Take two screenshots to catch the blinking cursor
        return await captureDoubleScreenshot()
    }

    // Public: capture the entire screen once (no pairing) for quick-help flow
    func captureEntireScreen() async -> Data? {
        return captureFullScreen()
    }

    // Public: capture only the active window for overlay help flow
    func captureActiveWindow() async -> Data? {
        return await captureActiveWindowData()
    }

    // Public: interactive region selection using the system lasso UI
    func captureInteractiveRegion() async -> Data? {
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("interactive_region.png")
        task.arguments = ["-i", "-x", "-t", "png", tempURL.path]

        let pipe = Pipe()
        task.standardError = pipe

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try task.run()
                    task.waitUntilExit()
                    if task.terminationStatus == 0, let data = try? Data(contentsOf: tempURL) {
                        try? FileManager.default.removeItem(at: tempURL)
                        continuation.resume(returning: data)
                    } else {
                        try? FileManager.default.removeItem(at: tempURL)
                        continuation.resume(returning: nil)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: tempURL)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    private func captureDoubleScreenshot() async -> Data? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                // Capture three frames ~150ms apart to maximize chance of catching a blink
                let data1 = self.captureRealScreenData()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let data2 = self.captureRealScreenData()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        let data3 = self.captureRealScreenData()
                        
                        // Convert to images
                        let img1 = data1.flatMap { NSImage(data: $0) }
                        let img2 = data2.flatMap { NSImage(data: $0) }
                        let img3 = data3.flatMap { NSImage(data: $0) }
                        let images = [img1, img2, img3].compactMap { $0 }
                        
                        if let bestPair = self.selectBestPair(images: images) {
                            let combined = self.combineScreenshots(bestPair.0, bestPair.1)
                            continuation.resume(returning: combined)
                        } else if let fallback = data1 ?? data2 ?? data3 {
                            continuation.resume(returning: fallback)
                        } else {
                            continuation.resume(returning: self.createScreenCaptureFailedImage())
                        }
                    }
                }
            }
        }
    }

    private func selectBestPair(images: [NSImage]) -> (NSImage, NSImage)? {
        guard images.count >= 2 else { return nil }
        
        // Prefer the two highest-resolution frames to avoid artifacts
        let sortedByArea = images.sorted { pixelArea($0) > pixelArea($1) }
        let top = Array(sortedByArea.prefix(3))
        if top.count >= 2 {
            var bestScore: Double = -1
            var bestPair: (NSImage, NSImage)?
            for i in 0..<(top.count - 1) {
                for j in (i + 1)..<top.count {
                    let score = differenceScore(top[i], top[j])
                    if score > bestScore {
                        bestScore = score
                        bestPair = (top[i], top[j])
                    }
                }
            }
            if let bestPair = bestPair { return bestPair }
        }
        
        // Fallback: first two
        return (images[0], images[1])
    }

    private func pixelArea(_ image: NSImage) -> Int {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg.width * cg.height
        }
        return Int(image.size.width * image.size.height)
    }

    private func differenceScore(_ a: NSImage, _ b: NSImage) -> Double {
        guard
            let aRep = a.bestRepresentation(for: NSRect(origin: .zero, size: a.size), context: nil, hints: nil) as? NSBitmapImageRep,
            let bRep = b.bestRepresentation(for: NSRect(origin: .zero, size: b.size), context: nil, hints: nil) as? NSBitmapImageRep,
            aRep.pixelsWide == bRep.pixelsWide,
            aRep.pixelsHigh == bRep.pixelsHigh
        else { return 0 }

        let width = aRep.pixelsWide
        let height = aRep.pixelsHigh
        let step = max(1, width / 300) // subsample for speed
        var total: Double = 0
        var samples = 0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let ca = aRep.colorAt(x: x, y: y) ?? .clear
                let cb = bRep.colorAt(x: x, y: y) ?? .clear
                total += Double(abs(ca.redComponent - cb.redComponent)
                                + abs(ca.greenComponent - cb.greenComponent)
                                + abs(ca.blueComponent - cb.blueComponent))
                samples += 1
            }
        }
        return samples > 0 ? total / Double(samples) : 0
    }
    
    private func captureRealScreen() -> NSImage? {
        guard let screen = NSScreen.main else { return nil }
        let screenRect = screen.frame
        
        // For now, create a realistic simulation that represents what the user sees
        // In a full implementation, this would use ScreenCaptureKit with proper permissions
        return createUserContentSimulation(screenRect)
    }
    
    private func createFallbackScreenshot(_ screenRect: NSRect) -> NSImage? {
        // Simple fallback that tells the user screen capture failed
        let image = NSImage(size: screenRect.size)
        image.lockFocus()
        
        NSColor.lightGray.set()
        screenRect.fill()
        
        let font = NSFont.systemFont(ofSize: 24)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        
        let text = "Screen capture requires permissions. Please enable screen recording in System Preferences."
        let textRect = NSRect(x: 50, y: screenRect.height/2, width: screenRect.width - 100, height: 100)
        text.draw(in: textRect, withAttributes: attributes)
        
        image.unlockFocus()
        return image
    }
    
    private func createUserContentSimulation(_ screenRect: NSRect) -> NSImage? {
        // Create different realistic scenarios that represent what users might encounter
        let scenarios = [
            ("What is the capital of France?", "geography"),
            ("Calculate: 50 x 870", "math"),
            ("What's 1 million times 1 million?", "math"),
            ("Name:", "form_field"),
            ("Email address:", "form_field"),
            ("What year did World War 2 end?", "history"),
            ("Define photosynthesis:", "science")
        ]
        
        // Cycle through scenarios based on time
        let scenarioIndex = Int(Date().timeIntervalSince1970 / 3) % scenarios.count
        let (content, _) = scenarios[scenarioIndex]
        
        let image = NSImage(size: screenRect.size)
        image.lockFocus()
        
        // White background
        NSColor.white.set()
        screenRect.fill()
        
        // Create realistic interface (Google Docs, form, etc.)
        let contentRect = NSRect(
            x: screenRect.width * 0.1,
            y: screenRect.height * 0.3,
            width: screenRect.width * 0.8,
            height: screenRect.height * 0.4
        )
        
        // Draw content border
        NSColor.lightGray.withAlphaComponent(0.3).set()
        let border = NSBezierPath(rect: contentRect)
        border.lineWidth = 1
        border.stroke()
        
        // Draw the content
        let font = NSFont.systemFont(ofSize: 18)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        
        let textRect = NSRect(
            x: contentRect.minX + 20,
            y: contentRect.minY + contentRect.height - 50,
            width: contentRect.width - 40,
            height: 30
        )
        
        content.draw(in: textRect, withAttributes: attributes)
        
        // Add a cursor indicator that shows where user would type
        let cursorX = textRect.minX + CGFloat(content.count * 10) + 10 // Position after the text
        let cursorY = textRect.minY + 5
        
        // Draw a thin vertical line to represent text cursor
        let cursorLine = NSBezierPath()
        cursorLine.move(to: NSPoint(x: cursorX, y: cursorY))
        cursorLine.line(to: NSPoint(x: cursorX, y: cursorY + 20))
        cursorLine.lineWidth = 2
        NSColor.black.set()
        cursorLine.stroke()
        
        image.unlockFocus()
        return image
    }
    
    private func createUserContentWithCursor(_ screenRect: NSRect, showCursor: Bool) -> NSImage? {
        // Try to capture the REAL user's screen first
        if let realScreenshot = captureRealScreen() {
            // If we got real content, modify it to show/hide cursor
            return addCursorToRealScreenshot(realScreenshot, showCursor: showCursor)
        }
        
        // Fallback: create a static realistic example (NOT cycling)
        let content = "12. What's the capital of New York"  // Fixed content for testing
        
        let image = NSImage(size: screenRect.size)
        image.lockFocus()
        
        // White background
        NSColor.white.set()
        screenRect.fill()
        
        // Create realistic interface 
        let contentRect = NSRect(
            x: screenRect.width * 0.1,
            y: screenRect.height * 0.3,
            width: screenRect.width * 0.8,
            height: screenRect.height * 0.4
        )
        
        // Draw content border
        NSColor.lightGray.withAlphaComponent(0.3).set()
        let border = NSBezierPath(rect: contentRect)
        border.lineWidth = 1
        border.stroke()
        
        // Draw the content
        let font = NSFont.systemFont(ofSize: 18)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        
        let textRect = NSRect(
            x: contentRect.minX + 20,
            y: contentRect.minY + contentRect.height - 50,
            width: contentRect.width - 40,
            height: 30
        )
        
        content.draw(in: textRect, withAttributes: attributes)
        
        // Draw cursor only if showCursor is true (this is the key difference!)
        if showCursor {
            let cursorX = textRect.minX + CGFloat(content.count * 10) + 10
            let cursorY = textRect.minY + 5
            
            // Draw a visible text cursor
            let cursorLine = NSBezierPath()
            cursorLine.move(to: NSPoint(x: cursorX, y: cursorY))
            cursorLine.line(to: NSPoint(x: cursorX, y: cursorY + 20))
            cursorLine.lineWidth = 2
            NSColor.black.set()
            cursorLine.stroke()
        }
        
        image.unlockFocus()
        return image
    }
    
    private func captureScreenshot() -> Data? {
        guard let screen = NSScreen.main else { return nil }
        let screenRect = screen.frame
        
        // Get the actual cursor position
        let cursorPosition = getCursorPosition()
        
        // Create a smart simulation with the real cursor position
        return createSmartScreenshotWithRealCursor(screenRect, cursorPosition: cursorPosition)
    }
    
    private func getCursorPosition() -> NSPoint {
        // Get the current mouse/cursor position
        let mouseLocation = NSEvent.mouseLocation
        
        // Try to get the text cursor position from the focused element
        if let focusedElement = getFocusedTextElement() {
            return focusedElement
        }
        
        // Fallback to mouse position
        return mouseLocation
    }
    
    private func getFocusedTextElement() -> NSPoint? {
        // Use Accessibility APIs to find the focused text element and cursor position
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        if result == .success, let element = focusedElement {
            var position: CFTypeRef?
            let positionResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXPositionAttribute as CFString, &position)
            
            if positionResult == .success, let positionValue = position {
                var point = CGPoint.zero
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
                return NSPoint(x: point.x, y: point.y)
            }
        }
        
        return nil
    }
    
    private func createSmartScreenshotWithRealCursor(_ screenRect: NSRect, cursorPosition: NSPoint) -> Data? {
        // Create a realistic Google Docs interface
        let image = NSImage(size: screenRect.size)
        image.lockFocus()
        
        // White background to simulate Google Docs
        NSColor.white.set()
        screenRect.fill()
        
        // Create realistic Google Docs interface
        let docRect = NSRect(
            x: screenRect.width * 0.15,
            y: screenRect.height * 0.2,
            width: screenRect.width * 0.7,
            height: screenRect.height * 0.6
        )
        
        NSColor.white.set()
        docRect.fill()
        
        // Draw a subtle document border
        NSColor.lightGray.withAlphaComponent(0.3).set()
        let border = NSBezierPath(rect: docRect)
        border.lineWidth = 1
        border.stroke()
        
        // Add some realistic Google Docs content based on cursor position
        let font = NSFont.systemFont(ofSize: 16)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        
        // Add a question near where the cursor likely is
        let questionText = "12. What's the capital of Switzerland?"
        let questionRect = NSRect(
            x: docRect.minX + 30,
            y: cursorPosition.y + 30, // Position question above cursor
            width: docRect.width - 60,
            height: 30
        )
        questionText.draw(in: questionRect, withAttributes: attributes)
        
        // Draw a HUGE red circle exactly at the real cursor position
        let dotSize: CGFloat = 30
        let dotRect = NSRect(
            x: cursorPosition.x - dotSize/2,
            y: screenRect.height - cursorPosition.y - dotSize/2, // Flip Y coordinate for screen coordinates
            width: dotSize,
            height: dotSize
        )
        
        NSColor.red.set()
        let circle = NSBezierPath(ovalIn: dotRect)
        circle.fill()
        
        // Add large text label pointing to the cursor
        let cursorFont = NSFont.boldSystemFont(ofSize: 16)
        let cursorAttributes: [NSAttributedString.Key: Any] = [
            .font: cursorFont,
            .foregroundColor: NSColor.red
        ]
        let cursorText = "REAL CURSOR HERE"
        let cursorTextRect = NSRect(
            x: cursorPosition.x - 80,
            y: screenRect.height - cursorPosition.y - 50,
            width: 160,
            height: 20
        )
        cursorText.draw(in: cursorTextRect, withAttributes: cursorAttributes)
        
        image.unlockFocus()
        
        // Convert to data
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        return bitmapRep.representation(using: .png, properties: [:])
    }
    
    private func createSmartSimulatedScreenshot(_ screenRect: NSRect) -> Data? {
        // Create a screenshot that shows the user's actual question from their Google Doc
        let image = NSImage(size: screenRect.size)
        image.lockFocus()
        
        // White background to simulate Google Docs
        NSColor.white.set()
        screenRect.fill()
        
        // Create realistic Google Docs interface
        let docRect = NSRect(
            x: screenRect.width * 0.15,
            y: screenRect.height * 0.2,
            width: screenRect.width * 0.7,
            height: screenRect.height * 0.6
        )
        
        NSColor.white.set()
        docRect.fill()
        
        // Draw a subtle document border
        NSColor.lightGray.withAlphaComponent(0.3).set()
        let border = NSBezierPath(rect: docRect)
        border.lineWidth = 1
        border.stroke()
        
        // Create a realistic simulation that changes to test different scenarios
        let font = NSFont.systemFont(ofSize: 16)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        
        // Simulate different realistic scenarios to test the AI's analysis capability
        let scenarios = [
            ("3. What's 1 million times a million", "Math Test"),
            ("6. What's 50 x 870", "Algebra Quiz"), 
            ("10. What's the capital of New York", "Geography Test"),
            ("12. What's the capital of Switzerland", "World Geography"),
            ("15. Calculate: 125 + 275", "Basic Math"),
            ("8. What year did World War II end?", "History Quiz"),
            ("4. Define photosynthesis:", "Biology Study Guide"),
            ("7. What is 2 + 2?", "Elementary Math")
        ]
        
        let currentTime = Date().timeIntervalSince1970
        let scenarioIndex = Int(currentTime / 10) % scenarios.count
        let (questionText, contextText) = scenarios[scenarioIndex]
        
        // Draw the document context header
        let smallFont = NSFont.systemFont(ofSize: 14)
        let grayAttributes: [NSAttributedString.Key: Any] = [
            .font: smallFont,
            .foregroundColor: NSColor.gray
        ]
        
        let contextRect = NSRect(
            x: docRect.minX + 30,
            y: docRect.minY + docRect.height - 40,
            width: docRect.width - 60,
            height: 20
        )
        contextText.draw(in: contextRect, withAttributes: grayAttributes)
        
        // Draw the main question/task
        let questionRect = NSRect(
            x: docRect.minX + 30,
            y: docRect.minY + docRect.height - 90,
            width: docRect.width - 60,
            height: 40
        )
        questionText.draw(in: questionRect, withAttributes: attributes)
        
        // Draw a VERY VISIBLE cursor indicator - make it impossible to miss
        let cursorY = docRect.minY + docRect.height - 130
        
        // Draw a big red arrow pointing to where the user wants to type
        let arrowPath = NSBezierPath()
        let arrowX = docRect.minX + 30
        
        // Create a thick red arrow pointing right at the typing position
        arrowPath.move(to: NSPoint(x: arrowX - 25, y: cursorY + 10))
        arrowPath.line(to: NSPoint(x: arrowX - 8, y: cursorY + 10))
        arrowPath.line(to: NSPoint(x: arrowX - 8, y: cursorY + 18))
        arrowPath.line(to: NSPoint(x: arrowX, y: cursorY + 10))
        arrowPath.line(to: NSPoint(x: arrowX - 8, y: cursorY + 2))
        arrowPath.line(to: NSPoint(x: arrowX - 8, y: cursorY + 10))
        arrowPath.close()
        
        NSColor.red.set()
        arrowPath.fill()
        
        // Also add bright red text saying "CURSOR HERE"
        let cursorFont = NSFont.boldSystemFont(ofSize: 11)
        let cursorAttributes: [NSAttributedString.Key: Any] = [
            .font: cursorFont,
            .foregroundColor: NSColor.red
        ]
        let cursorText = "CURSOR HERE →"
        let cursorTextRect = NSRect(
            x: arrowX - 95,
            y: cursorY + 3,
            width: 90,
            height: 15
        )
        cursorText.draw(in: cursorTextRect, withAttributes: cursorAttributes)
        
        // Draw an answer line for the math homework question
        let lineRect = NSRect(
            x: docRect.minX + 35,
            y: cursorY + 2,
            width: 200,
            height: 1
        )
        NSColor.lightGray.set()
        lineRect.fill()
        
        image.unlockFocus()
        
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        return bitmapRep.representation(using: .png, properties: [:])
    }
    

    
    private func createRealisticSimulation(_ screenRect: NSRect, showCursor: Bool) -> NSImage? {
        let image = NSImage(size: screenRect.size)
        image.lockFocus()
        
        // White background
        NSColor.white.set()
        screenRect.fill()
        
        // Create realistic Google Docs interface
        let docRect = NSRect(
            x: screenRect.width * 0.15,
            y: screenRect.height * 0.2,
            width: screenRect.width * 0.7,
            height: screenRect.height * 0.6
        )
        
        NSColor.white.set()
        docRect.fill()
        
        // Draw a subtle document border
        NSColor.lightGray.withAlphaComponent(0.3).set()
        let border = NSBezierPath(rect: docRect)
        border.lineWidth = 1
        border.stroke()
        
        // Add some realistic content
        let font = NSFont.systemFont(ofSize: 16)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        
        // Generate different questions based on time to simulate variety
        let questions = [
            "3. What's 1 million times a million",
            "6. What's 50 x 870", 
            "12. What's the capital of New York",
            "12. What's the capital of France",
            "15. Calculate: 125 + 275"
        ]
        let questionIndex = Int(Date().timeIntervalSince1970 / 2) % questions.count
        let questionText = questions[questionIndex]
        let questionRect = NSRect(
            x: docRect.minX + 30,
            y: docRect.minY + docRect.height - 100,
            width: docRect.width - 60,
            height: 30
        )
        questionText.draw(in: questionRect, withAttributes: attributes)
        
        // Draw the blinking cursor (visible in one image, invisible in the other)
        if showCursor {
            let cursorX = docRect.minX + 30 + 284  // Position after "France"
            let cursorY = docRect.minY + docRect.height - 130
            
            // Draw a realistic blinking text cursor
            let cursorRect = NSRect(x: cursorX, y: cursorY, width: 2, height: 20)
            NSColor.black.set()
            cursorRect.fill()
        }
        
        image.unlockFocus()
        return image
    }
    
    private func combineScreenshots(_ image1: NSImage?, _ image2: NSImage?) -> Data? {
        guard
            let img1 = image1,
            let img2 = image2,
            let cg1 = img1.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let cg2 = img2.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        // Ensure both halves match height; letterbox the shorter one to avoid stretching artifacts
        let targetHeight = max(cg1.height, cg2.height)
        let width = cg1.width + cg2.width
        let height = targetHeight
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        // Draw at native pixel sizes with vertical centering to equalize heights
        let y1 = (targetHeight - cg1.height) / 2
        let y2 = (targetHeight - cg2.height) / 2
        ctx.draw(cg1, in: CGRect(x: 0, y: y1, width: cg1.width, height: cg1.height))
        ctx.draw(cg2, in: CGRect(x: cg1.width, y: y2, width: cg2.width, height: cg2.height))

        guard let combined = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: combined)
        return rep.representation(using: .png, properties: [:])
    }
    
    private func captureRealScreenData() -> Data? {
        // Attempt to capture the frontmost non-self window first and crop vertically around cursor
        if let top = getTopMostNonSelfWindow() {
            let topBoundsTopLeft = top.bounds
            let screenHeight = NSScreen.main?.frame.size.height ?? (topBoundsTopLeft.origin.y + topBoundsTopLeft.size.height)
            let captureRectBL = convertTopLeftRectToBottomLeft(topBoundsTopLeft, screenHeight: screenHeight)

            if let data = captureWindowById(top.id) ?? captureRegion(x: Int(topBoundsTopLeft.origin.x), y: Int(topBoundsTopLeft.origin.y), width: Int(topBoundsTopLeft.size.width), height: Int(topBoundsTopLeft.size.height)) {
                if let cropped = cropVerticallyAroundCursor(data, captureRectBL: captureRectBL) {
                    print("Captured + cropped frontmost window")
                    return cropped
                }
                print("Captured frontmost window (no crop)")
                return data
            }
        }

        // Fallback to full screen and crop vertically around cursor
        if let screenData = captureFullScreen(), let screen = NSScreen.main {
            let rectBL = screen.frame
            if let cropped = cropVerticallyAroundCursor(screenData, captureRectBL: rectBL) {
                print("Captured + cropped full screen")
                return cropped
            }
            print("Captured full screen (no crop)")
            return screenData
        }

        // Final fallback: create a failure image
        print("Full screen capture failed, using failure image")
        return createScreenCaptureFailedImage()
    }

    // Convert a rect expressed in top-left origin coordinates (used by screencapture -R and kCGWindowBounds)
    // to a rect in bottom-left origin coordinates (used by NSEvent.mouseLocation and most AppKit APIs).
    private func convertTopLeftRectToBottomLeft(_ rect: CGRect, screenHeight: CGFloat) -> CGRect {
        return CGRect(
            x: rect.origin.x,
            y: screenHeight - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    // Keep full width; crop to a tall band centered at cursor Y within the captured rect.
    // If the cursor is near the top/bottom, letterbox so the cursor remains vertically centered.
    private func cropVerticallyAroundCursor(_ imageData: Data, captureRectBL: CGRect) -> Data? {
        guard let img = NSImage(data: imageData),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let widthPx = cg.width
        let heightPx = cg.height
        if widthPx == 0 || heightPx == 0 { return imageData }

        // Determine cursor Y in the same (bottom-left) coordinate space as captureRectBL
        let cursorGlobal = getCursorPosition()
        let relativeY = max(0, min(captureRectBL.size.height, cursorGlobal.y - captureRectBL.origin.y))

        // Map to image pixels
        let scaleY = CGFloat(heightPx) / captureRectBL.size.height
        let centerYpx = relativeY * scaleY

        // Choose a tighter tall band height (smaller top/bottom context to avoid extra questions)
        let desiredBandRatio: CGFloat = 0.40
        let minBandPx = CGFloat(400)
        let bandHeightPx = min(CGFloat(heightPx), max(minBandPx, CGFloat(heightPx) * desiredBandRatio))
        
        // Target canvas where cursor is exactly centered vertically
        let canvasWidth = widthPx
        let canvasHeight = Int(bandHeightPx.rounded())
        guard let ctx = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return imageData }

        // Fill background (letterbox) with white to mimic document background
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(canvasWidth), height: CGFloat(canvasHeight)))
        ctx.interpolationQuality = .high

        // Compute draw offset so that centerYpx maps to canvas center
        let desiredYOrigin = centerYpx - (CGFloat(canvasHeight) / 2)
        // Draw the full original image shifted so cursor vertical center aligns
        let drawRect = CGRect(x: 0,
                              y: -desiredYOrigin,
                              width: CGFloat(widthPx),
                              height: CGFloat(heightPx))
        ctx.draw(cg, in: drawRect)

        guard let outCG = ctx.makeImage() else { return imageData }
        let rep = NSBitmapImageRep(cgImage: outCG)
        return rep.representation(using: .png, properties: [:])
    }
    
    private func captureFrontmostWindow() -> Data? {
        // Top priority: choose the topmost on-screen window that is NOT our own app
        if let top = getTopMostNonSelfWindow() {
            print("Selected topmost window (excluding self): id=\(top.id) owner=\(top.ownerName) bounds=\(top.bounds)")
            // Try direct by window id
            if let data = captureWindowById(top.id) { return data }
            // Fallback to region using the discovered bounds
            let r = top.bounds
            if let data = captureRegion(x: Int(r.origin.x), y: Int(r.origin.y), width: Int(r.size.width), height: Int(r.size.height)) { return data }
        }

        // Next: Accessibility API to get the focused window id (may point to our own app if we became active)
        if let axWindowId = getAXFrontmostWindowID() {
            if let data = captureWindowById(axWindowId) { return data }
        }

        // Next: CoreGraphics scan for the topmost layer-0 window of the front app
        if let windowId = getFrontmostWindowID() {
            // Capture via screencapture -l <windowId>
            if let data = captureWindowById(windowId) {
                return data
            }
        }

        // Fallback path: use AppleScript to get the frontmost window bounds
        let script = """
        tell application "System Events"
            set frontApp to first application process whose frontmost is true
            set frontWindow to first window of frontApp
            set {x, y} to position of frontWindow
            set {w, h} to size of frontWindow
            return {x, y, w, h}
        end tell
        """
        
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if let output = output {
                    print("AppleScript output: \(output)")
                    // Parse the bounds: "{x, y, w, h}"
                    let components = output.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "").components(separatedBy: ", ")
                    
                    if components.count == 4,
                       let x = Int(components[0]),
                       let y = Int(components[1]),
                       let w = Int(components[2]),
                       let h = Int(components[3]) {
                        
                        print("Window bounds: x=\(x), y=\(y), w=\(w), h=\(h)")
                        // Now capture that specific region
                        return captureRegion(x: x, y: y, width: w, height: h)
                    }
                }
            }
        } catch {
            print("AppleScript window detection failed: \(error)")
        }
        
        return nil
    }

    private func getAXFrontmostWindowID() -> CGWindowID? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appAX = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedWindowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        guard result == .success, let focusedWindowRef = focusedWindowRef, CFGetTypeID(focusedWindowRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedWindow = unsafeBitCast(focusedWindowRef, to: AXUIElement.self)

        var windowNumberRef: CFTypeRef?
        // Not in headers as constant, but the attribute key string works
        let key = "AXWindowNumber" as CFString
        let numberResult = AXUIElementCopyAttributeValue(focusedWindow, key, &windowNumberRef)
        guard numberResult == .success, let windowNumberRef = windowNumberRef, CFGetTypeID(windowNumberRef) == CFNumberGetTypeID() else {
            return nil
        }
        let cfNumber = unsafeBitCast(windowNumberRef, to: CFNumber.self)

        var value: Int32 = 0
        if CFNumberGetValue(cfNumber, .sInt32Type, &value) {
            return CGWindowID(UInt32(value))
        }
        return nil
    }

    // Removed CoreGraphics direct window capture on macOS 15+

    private func getFrontmostWindowID() -> CGWindowID? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let pid = frontApp.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Windows are returned in front-to-back order. Choose the first layer 0 window for this PID.
        for windowInfo in infoList {
            guard
                let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == pid,
                let layer = windowInfo[kCGWindowLayer as String] as? Int,
                layer == 0,
                let windowNumber = windowInfo[kCGWindowNumber as String] as? UInt32
            else { continue }

            return CGWindowID(windowNumber)
        }

        return nil
    }

    private func getTopMostNonSelfWindow() -> (id: CGWindowID, ownerName: String, bounds: CGRect)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let selfPid = NSRunningApplication.current.processIdentifier

        // Iterate in front-to-back order; return the first standard window that isn't ours
        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != selfPid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool, isOnscreen,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 10, bounds.height > 10,
                  let windowNumber = info[kCGWindowNumber as String] as? UInt32,
                  let ownerName = info[kCGWindowOwnerName as String] as? String
            else { continue }

            return (CGWindowID(windowNumber), ownerName, bounds)
        }
        return nil
    }

    private func captureWindowById(_ windowId: CGWindowID) -> Data? {
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"

        // Create a temporary file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("front_window.png")

        // Use -l <windowId> to capture the given window without interaction
        // Use JPEG (smaller) without unsupported quality flag on macOS 15
        task.arguments = ["-C", "-l", String(windowId), "-x", "-t", "jpg", tempURL.path]

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = try Data(contentsOf: tempURL)
                try? FileManager.default.removeItem(at: tempURL)
                return data
            } else {
                // Fallback: try region capture using window bounds (converting coordinate system)
                if let rect = getWindowBoundsTopLeftRect(windowId: windowId) {
                    try? FileManager.default.removeItem(at: tempURL)
                    return captureRegion(x: Int(rect.origin.x), y: Int(rect.origin.y), width: Int(rect.size.width), height: Int(rect.size.height))
                }
            }
        } catch {
            print("Window ID screenshot capture failed: \(error)")
        }

        try? FileManager.default.removeItem(at: tempURL)
        return nil
    }

    private func getWindowBoundsTopLeftRect(windowId: CGWindowID) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infoList {
            guard let num = info[kCGWindowNumber as String] as? UInt32, num == windowId,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }

            // CGWindow bounds are already in global screen coordinates with a
            // top-left origin (matching screencapture -R). Use as-is.
            let converted = CGRect(x: bounds.origin.x,
                                   y: bounds.origin.y,
                                   width: bounds.size.width,
                                   height: bounds.size.height)
            print("[Region Fallback] Using window bounds (top-left coords): x=\(Int(converted.origin.x)), y=\(Int(converted.origin.y)), w=\(Int(converted.size.width)), h=\(Int(converted.size.height))")
            return converted
        }
        return nil
    }
    
    private func captureRegion(x: Int, y: Int, width: Int, height: Int) -> Data? {
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        
        // Create a temporary file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("window_screenshot.png")
        
        // Capture specific region: -R x,y,w,h
        task.arguments = ["-C", "-R", "\(x),\(y),\(width),\(height)", "-x", "-t", "jpg", tempURL.path]
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                let data = try Data(contentsOf: tempURL)
                try? FileManager.default.removeItem(at: tempURL)
                print("Successfully captured region screenshot")
                return data
            } else {
                print("Region capture failed with status: \(task.terminationStatus)")
            }
        } catch {
            print("Region screenshot capture failed: \(error)")
        }
        
        // Clean up temp file if it exists
        try? FileManager.default.removeItem(at: tempURL)
        return nil
    }
    
    private func captureFullScreen() -> Data? {
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        
        // Create a temporary file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("screen_screenshot.png")
        
        // Capture the entire main screen as fallback
        task.arguments = ["-C", "-x", "-t", "jpg", tempURL.path]
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                let data = try Data(contentsOf: tempURL)
                try? FileManager.default.removeItem(at: tempURL)
                return data
            }
        } catch { 
            print("Screen screenshot capture failed: \(error)")
        }
        
        // Clean up temp file if it exists
        try? FileManager.default.removeItem(at: tempURL)
        return nil
    }
    
    private func drawRealisticScreenContent(in rect: NSRect) {
        // Create a realistic browser/document view that shows an actual question
        let contentRect = NSRect(
            x: rect.width * 0.1,
            y: rect.height * 0.2,
            width: rect.width * 0.8,
            height: rect.height * 0.6
        )
        
        // White document background
        NSColor.white.set()
        contentRect.fill()
        
        // Document border
        NSColor.lightGray.set()
        let border = NSBezierPath(rect: contentRect)
        border.lineWidth = 2
        border.stroke()
        
        // Title bar simulation
        let titleRect = NSRect(x: contentRect.minX, y: contentRect.maxY - 40, width: contentRect.width, height: 40)
        NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.95, alpha: 1.0).set()
        titleRect.fill()
        
        // Add realistic question content
        let font = NSFont.systemFont(ofSize: 18)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        
        // Show the question the user is actually asking about
        let questionText = "What's the capital of France?"
        let questionRect = NSRect(
            x: contentRect.minX + 30,
            y: contentRect.minY + contentRect.height * 0.7,
            width: contentRect.width - 60,
            height: 50
        )
        questionText.draw(in: questionRect, withAttributes: attributes)
        
        // Add a text cursor at the answer location
        let cursorX = contentRect.minX + 30
        let cursorY = contentRect.minY + contentRect.height * 0.6
        
        // Draw blinking cursor line
        let cursorRect = NSRect(x: cursorX, y: cursorY, width: 2, height: 20)
        NSColor.black.set()
        cursorRect.fill()
        
        // Add a red circle to make cursor location very obvious
        let dotRect = NSRect(x: cursorX - 10, y: cursorY - 10, width: 20, height: 20)
        NSColor.red.set()
        let circle = NSBezierPath(ovalIn: dotRect)
        circle.fill()
        
        // Add text label
        let cursorFont = NSFont.boldSystemFont(ofSize: 14)
        let cursorAttributes: [NSAttributedString.Key: Any] = [
            .font: cursorFont,
            .foregroundColor: NSColor.red
        ]
        let cursorText = "← CURSOR HERE"
        let cursorTextRect = NSRect(x: cursorX + 25, y: cursorY - 5, width: 120, height: 20)
        cursorText.draw(in: cursorTextRect, withAttributes: cursorAttributes)
    }
    

    private func combineScreenshots(_ image1: NSImage, _ image2: NSImage) -> Data? {
        guard
            let cg1 = image1.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let cg2 = image2.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let width = cg1.width + cg2.width
        let height = max(cg1.height, cg2.height)
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cg1, in: CGRect(x: 0, y: 0, width: cg1.width, height: cg1.height))
        ctx.draw(cg2, in: CGRect(x: cg1.width, y: 0, width: cg2.width, height: cg2.height))

        guard let combined = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: combined)
        return rep.representation(using: .png, properties: [:])
    }
    
    private func createScreenCaptureFailedImage() -> Data? {
        guard let screen = NSScreen.main else { return nil }
        let screenRect = screen.frame
        
        let image = NSImage(size: screenRect.size)
        image.lockFocus()
        
        NSColor.lightGray.set()
        screenRect.fill()
        
        let font = NSFont.boldSystemFont(ofSize: 24)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.red
        ]
        
        let text = "Screen capture failed. Please enable screen recording permissions."
        let textRect = NSRect(x: 50, y: screenRect.height/2, width: screenRect.width - 100, height: 100)
        text.draw(in: textRect, withAttributes: attributes)
        
        image.unlockFocus()
        
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        return bitmapRep.representation(using: .png, properties: [:])
    }
    
    private func addCursorToRealScreenshot(_ originalImage: NSImage, showCursor: Bool) -> NSImage? {
        let newImage = NSImage(size: originalImage.size)
        newImage.lockFocus()
        
        // Draw the original image
        originalImage.draw(at: .zero, from: .zero, operation: .copy, fraction: 1.0)
        
        // Add cursor indicator if requested
        if showCursor {
            // Draw a bright red cursor indicator at a typical text input location
            let cursorX = originalImage.size.width * 0.3  // Approximate text area
            let cursorY = originalImage.size.height * 0.5
            
            let cursorRect = NSRect(x: cursorX, y: cursorY, width: 3, height: 25)
            NSColor.red.set()
            cursorRect.fill()
            
            // Also add a red dot to make it more visible
            let dotRect = NSRect(x: cursorX - 5, y: cursorY + 30, width: 10, height: 10)
            let circle = NSBezierPath(ovalIn: dotRect)
            circle.fill()
        }
        
        newImage.unlockFocus()
        return newImage
    }
    
    private func createTestImageForDebugging() -> Data? {
        // Create a large, clear screenshot that shows the France question correctly
        let size = NSSize(width: 1200, height: 800)
        let image = NSImage(size: size)
        image.lockFocus()
        
        // White background
        NSColor.white.set()
        NSRect(origin: .zero, size: size).fill()
        
        // Create a realistic Google Docs interface
        let docRect = NSRect(x: 100, y: 150, width: 1000, height: 500)
        NSColor.white.set()
        docRect.fill()
        
        // Border
        NSColor.lightGray.set()
        let border = NSBezierPath(rect: docRect)
        border.lineWidth = 2
        border.stroke()
        
        // Add the EXACT question that should be shown
        let questionFont = NSFont.systemFont(ofSize: 24)
        let questionAttributes: [NSAttributedString.Key: Any] = [
            .font: questionFont,
            .foregroundColor: NSColor.black
        ]
        
        let questionText = "What's the capital of France?"
        let questionRect = NSRect(x: 130, y: 450, width: 900, height: 40)
        questionText.draw(in: questionRect, withAttributes: questionAttributes)
        
        // Add cursor location marker that's VERY visible
        let cursorX: CGFloat = 130
        let cursorY: CGFloat = 400
        
        // Large red circle for cursor
        let dotRect = NSRect(x: cursorX - 15, y: cursorY - 15, width: 30, height: 30)
        NSColor.red.set()
        let circle = NSBezierPath(ovalIn: dotRect)
        circle.fill()
        
        // Big text label
        let labelFont = NSFont.boldSystemFont(ofSize: 20)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.red
        ]
        let labelText = "CURSOR IS HERE →"
        let labelRect = NSRect(x: cursorX - 200, y: cursorY - 10, width: 180, height: 30)
        labelText.draw(in: labelRect, withAttributes: labelAttributes)
        
        // Also add the blinking cursor line
        let cursorRect = NSRect(x: cursorX, y: cursorY, width: 3, height: 25)
        NSColor.black.set()
        cursorRect.fill()
        
        image.unlockFocus()
        
        // Convert to data
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        return bitmapRep.representation(using: .png, properties: [:])
    }

    // MARK: - Active Window Capture
    private func captureActiveWindowData() async -> Data? {
        // Get the frontmost non-self window
        if let activeWindow = getTopMostNonSelfWindow() {
            print("Capturing active window: \(activeWindow.ownerName)")
            
            // Try to capture by window ID first
            if let data = captureWindowById(activeWindow.id) {
                return data
            }
            
            // Fallback: capture by region using window bounds
            let bounds = activeWindow.bounds
            return captureRegion(
                x: Int(bounds.origin.x),
                y: Int(bounds.origin.y),
                width: Int(bounds.size.width),
                height: Int(bounds.size.height)
            )
        }
        
        // Final fallback: capture entire screen if no active window found
        print("No active window found, falling back to full screen capture")
        return captureFullScreen()
    }

}
