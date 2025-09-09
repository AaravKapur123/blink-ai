//
//  PermissionsManager.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

@MainActor
class PermissionsManager: ObservableObject {
    @Published var screenRecordingPermission = false
    @Published var accessibilityPermission = false
    @Published var allPermissionsGranted = false
    
    init() {
        checkPermissions()
    }
    
    func checkPermissions() {
        checkScreenRecordingPermission()
        checkAccessibilityPermission()
        allPermissionsGranted = screenRecordingPermission && accessibilityPermission
    }
    
    func requestPermissions() {
        requestScreenRecordingPermission()
        requestAccessibilityPermission()
    }
    
    private func checkScreenRecordingPermission() {
        if #available(macOS 10.15, *) {
            // Returns true only if the app has Screen Recording permission in System Settings
            screenRecordingPermission = CGPreflightScreenCaptureAccess()
        } else {
            screenRecordingPermission = true
        }
        allPermissionsGranted = screenRecordingPermission && accessibilityPermission
    }
    
    private func checkAccessibilityPermission() {
        accessibilityPermission = AXIsProcessTrusted()
        allPermissionsGranted = screenRecordingPermission && accessibilityPermission
    }
    
    private func requestScreenRecordingPermission() {
        if #available(macOS 10.15, *) {
            // Triggers the system prompt the first time; thereafter, user must enable in Settings
            let granted = CGRequestScreenCaptureAccess()
            screenRecordingPermission = granted
            allPermissionsGranted = screenRecordingPermission && accessibilityPermission
        } else {
            screenRecordingPermission = true
        }
        checkPermissions()
    }
    
    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        // Check again after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.checkPermissions()
        }
    }
    
    func openSystemPreferences() {
        // Open Screen Recording privacy page first, then Accessibility as fallback
        let screenURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        if !NSWorkspace.shared.open(screenURL) {
            let accURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(accURL)
        }
    }
}
