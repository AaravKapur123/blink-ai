//
//  FreeUsageLimiter.swift
//  UsefulMacApp
//
//  Persists per-day usage counts across app restarts (per feature), with
//  backward-compat helpers for the original free chat path.
//

import Foundation

final class FreeUsageLimiter {
    static let shared = FreeUsageLimiter()
    private init() {}

    private let limitPerDay: Int = 8 // legacy free chat limit
    private let defaults = UserDefaults.standard

    private func dateKey(for date: Date = Date()) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    private func key(userId: String?, feature: String, date: Date = Date()) -> String {
        let uid = (userId ?? "anon").trimmingCharacters(in: .whitespacesAndNewlines)
        let u = uid.isEmpty ? "anon" : uid
        return "usage::\(feature)::\(u)::\(dateKey(for: date))"
    }

    // Generic API
    func currentCount(userId: String?, feature: String) -> Int {
        let k = key(userId: userId, feature: feature)
        return max(0, defaults.integer(forKey: k))
    }

    func canUse(userId: String?, feature: String, limit: Int) -> Bool {
        return currentCount(userId: userId, feature: feature) < limit
    }

    @discardableResult
    func recordIfAllowed(userId: String?, feature: String, limit: Int) -> Bool {
        let k = key(userId: userId, feature: feature)
        let current = defaults.integer(forKey: k)
        if current >= limit { return false }
        defaults.set(current + 1, forKey: k)
        return true
    }

    // Back-compat helpers for existing free chat integration (8/day)
    func currentCount(userId: String?) -> Int { currentCount(userId: userId, feature: "chat_free") }
    func remaining(userId: String?) -> Int { max(0, limitPerDay - currentCount(userId: userId, feature: "chat_free")) }
    func canSend(userId: String?) -> Bool { canUse(userId: userId, feature: "chat_free", limit: limitPerDay) }
    @discardableResult
    func recordSendIfAllowed(userId: String?) -> Bool { recordIfAllowed(userId: userId, feature: "chat_free", limit: limitPerDay) }
}


