//
//  AuthenticationModels.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import Foundation

// MARK: - Authentication Models

struct AuthUser {
    let uid: String
    let email: String?
    let displayName: String?
    
    init(uid: String, email: String? = nil, displayName: String? = nil) {
        self.uid = uid
        self.email = email
        self.displayName = displayName
    }
}

enum UserTier: String, CaseIterable {
    case free = "free"
    case pro = "pro"
    case unlimited = "unlimited"
    
    var displayName: String {
        switch self {
        case .free:
            return "Free"
        case .pro:
            return "Pro"
        case .unlimited:
            return "Pro Unlimited"
        }
    }
    
    var description: String {
        switch self {
        case .free:
            return "Free tier"
        case .pro:
            return "Current Plan"
        case .unlimited:
            return "Included in your plan"
        }
    }
}

struct UserProfile {
    let user: AuthUser
    let tier: UserTier
    let createdAt: Date?
    let lastLoginAt: Date?
    
    init(user: AuthUser, tier: UserTier = .free, createdAt: Date? = nil, lastLoginAt: Date? = nil) {
        self.user = user
        self.tier = tier
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
    }
}

// MARK: - Authentication Errors

enum AuthenticationError: LocalizedError {
    case notAuthenticated
    case invalidCredentials
    case networkError(String)
    case firebaseError(String)
    case userDataNotFound
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "User is not authenticated"
        case .invalidCredentials:
            return "Invalid email or password"
        case .networkError(let message):
            return "Network error: \(message)"
        case .firebaseError(let message):
            return "Authentication error: \(message)"
        case .userDataNotFound:
            return "User profile not found"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
}

// MARK: - Authentication State

enum AuthenticationState {
    case loading
    case unauthenticated
    case authenticated(UserProfile)
    case error(AuthenticationError)
    
    var isAuthenticated: Bool {
        if case .authenticated = self {
            return true
        }
        return false
    }
    
    var userProfile: UserProfile? {
        if case .authenticated(let profile) = self {
            return profile
        }
        return nil
    }
    
    var error: AuthenticationError? {
        if case .error(let error) = self {
            return error
        }
        return nil
    }
}
