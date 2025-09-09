//
//  KeyboardShortcutManager.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import Foundation
import Carbon
import AppKit

class KeyboardShortcutManager: ObservableObject {
    static let shared = KeyboardShortcutManager()
    
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    
    private init() {
        setupEventHandler()
    }
    
    deinit {
        unregisterAllShortcuts()
    }
    
    // Generic registration
    func registerHotkey(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        var hkRef: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x12345678), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetEventDispatcherTarget(), 0, &hkRef)
        if status == noErr, let hkRef = hkRef {
            hotKeyRefs[id] = hkRef
            handlers[id] = handler
            print("Registered hotkey id=\(id) keyCode=\(keyCode) modifiers=\(modifiers)")
        } else {
            print("Failed to register hotkey id=\(id): status=\(status)")
        }
    }
    
    // Variant that returns whether registration succeeded
    func registerHotkeyIfAvailable(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        var hkRef: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x12345678), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetEventDispatcherTarget(), 0, &hkRef)
        if status == noErr, let hkRef = hkRef {
            hotKeyRefs[id] = hkRef
            handlers[id] = handler
            print("Registered hotkey (probe) id=\(id) keyCode=\(keyCode) modifiers=\(modifiers)")
            return true
        } else {
            print("Failed (probe) to register hotkey id=\(id): status=\(status)")
            return false
        }
    }
    
    func unregisterAllShortcuts() {
        for (_, ref) in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        handlers.removeAll()
    }
    
    func unregisterHotkey(id: UInt32) {
        if let ref = hotKeyRefs[id] {
            UnregisterEventHotKey(ref)
            hotKeyRefs.removeValue(forKey: id)
            handlers.removeValue(forKey: id)
            print("Unregistered hotkey id=\(id)")
        }
    }
    
    private func setupEventHandler() {
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))]
        
        let callback: EventHandlerUPP = { (nextHandler, event, userData) in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            
            if status == noErr {
                if let manager = Unmanaged<KeyboardShortcutManager>.fromOpaque(userData!).takeUnretainedValue() as KeyboardShortcutManager? {
                    let id = hotKeyID.id
                    DispatchQueue.main.async {
                        if let handler = manager.handlers[id] { handler() }
                    }
                }
            }
            
            return noErr
        }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &eventTypes, selfPtr, nil)
    }
}
