//
//  AuthenticationManager.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn
import Combine

@MainActor
class AuthenticationManager: ObservableObject {
    static let shared = AuthenticationManager()
    
    @Published var authState: AuthenticationState = .loading
    @Published var isInitialized = false
    
    private var authStateListener: AuthStateDidChangeListenerHandle?
    private var userProfileListener: ListenerRegistration?
    private var db: Firestore?
    
    private init() {
        initializeFirebase()
    }
    
    deinit {
        if let listener = authStateListener {
            Auth.auth().removeStateDidChangeListener(listener)
        }
        userProfileListener?.remove()
    }
    
    // MARK: - Firebase Initialization
    
    private func initializeFirebase() {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") else {
            print("❌ GoogleService-Info.plist not found in bundle")
            self.authState = .error(.firebaseError("GoogleService-Info.plist not found. Please add it to your Xcode project."))
            self.isInitialized = true // Mark as initialized even if failed, to show error
            return
        }
        
        guard let options = FirebaseOptions(contentsOfFile: path) else {
            print("❌ Failed to parse GoogleService-Info.plist")
            self.authState = .error(.firebaseError("Invalid GoogleService-Info.plist file"))
            self.isInitialized = true
            return
        }
        
        if FirebaseApp.app() == nil {
            FirebaseApp.configure(options: options)
        }
        
        // Initialize Firestore after Firebase is configured
        self.db = Firestore.firestore()
        
        // Configure Google Sign-In
        guard let clientId = options.clientID else {
            print("❌ Google Sign-In client ID not found")
            self.authState = .error(.firebaseError("Google Sign-In not configured"))
            return
        }
        
        let config = GIDConfiguration(clientID: clientId)
        GIDSignIn.sharedInstance.configuration = config
        
        // Set up auth state listener
        setupAuthStateListener()
        
        self.isInitialized = true
        print("✅ Firebase initialized successfully")
    }
    
    // MARK: - Auth State Management
    
    private func setupAuthStateListener() {
        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self = self else { return }
                
                if let user = user {
                    // User is signed in
                    await self.handleUserSignedIn(user)
                } else {
                    // User is signed out
                    self.authState = .unauthenticated
                    self.userProfileListener?.remove()
                    self.userProfileListener = nil
                }
            }
        }
    }
    
    private func handleUserSignedIn(_ firebaseUser: User) async {
        let authUser = AuthUser(
            uid: firebaseUser.uid,
            email: firebaseUser.email,
            displayName: firebaseUser.displayName
        )
        
        // Listen for user profile changes in Firestore
        setupUserProfileListener(uid: authUser.uid)
        
        // Initially set authenticated state with default tier
        // The Firestore listener will update with the actual tier
        let initialProfile = UserProfile(user: authUser, tier: .free)
        self.authState = .authenticated(initialProfile)
    }
    
    private func setupUserProfileListener(uid: String) {
        userProfileListener?.remove()
        
        guard let db = self.db else { return }
        
        userProfileListener = db.collection("users").document(uid).addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self = self else { return }
                
                if let error = error {
                    print("❌ Error listening to user profile: \(error)")
                    return
                }
                
                guard let snapshot = snapshot else { return }
                
                // Get current user from auth state
                guard case .authenticated(let currentProfile) = self.authState else { return }
                
                let tierString = snapshot.data()?["tier"] as? String ?? "free"
                let tier = UserTier(rawValue: tierString.lowercased()) ?? .free
                
                let createdAt = (snapshot.data()?["createdAt"] as? Timestamp)?.dateValue()
                let lastLoginAt = (snapshot.data()?["lastLoginAt"] as? Timestamp)?.dateValue()
                
                let updatedProfile = UserProfile(
                    user: currentProfile.user,
                    tier: tier,
                    createdAt: createdAt,
                    lastLoginAt: lastLoginAt
                )
                
                self.authState = .authenticated(updatedProfile)
            }
        }
    }
    
    // MARK: - Authentication Methods
    
    func signInWithGoogle() async throws {
        guard let presentingWindow = NSApplication.shared.mainWindow else {
            throw AuthenticationError.unknown("No window available for sign-in")
        }
        
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingWindow)
            
            let user = result.user
            guard let idToken = user.idToken?.tokenString else {
                throw AuthenticationError.firebaseError("Failed to get ID token")
            }
            
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: user.accessToken.tokenString
            )
            
            let authResult = try await Auth.auth().signIn(with: credential)
            await updateUserProfile(user: authResult.user, isNewUser: result.user.profile?.email != nil)
            
        } catch {
            print("❌ Google Sign-In error: \(error)")
            
            // Handle specific Google Sign-In errors
            if let gidError = error as? GIDSignInError {
                switch gidError.code {
                case .canceled:
                    throw AuthenticationError.unknown("Sign-in was cancelled")
                case .keychain:
                    throw AuthenticationError.firebaseError("Keychain error. Please check app permissions and try again.")
                case .hasNoAuthInKeychain:
                    throw AuthenticationError.firebaseError("No authentication data found. Please try signing in again.")
                case .unknown:
                    throw AuthenticationError.firebaseError("Unknown Google Sign-In error: \(gidError.localizedDescription)")
                @unknown default:
                    throw AuthenticationError.firebaseError("Google Sign-In error: \(gidError.localizedDescription)")
                }
            } else {
                throw AuthenticationError.firebaseError(error.localizedDescription)
            }
        }
    }
    
    func signInWithEmail(_ email: String, password: String) async throws {
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            await updateUserProfile(user: result.user, isNewUser: false)
        } catch {
            print("❌ Email sign-in error: \(error)")
            throw AuthenticationError.invalidCredentials
        }
    }
    
    func createAccountWithEmail(_ email: String, password: String) async throws {
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            await updateUserProfile(user: result.user, isNewUser: true)
        } catch {
            print("❌ Account creation error: \(error)")
            throw AuthenticationError.firebaseError(error.localizedDescription)
        }
    }
    
    func signOut() async throws {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
        } catch {
            print("❌ Sign-out error: \(error)")
            throw AuthenticationError.firebaseError(error.localizedDescription)
        }
    }
    
    // Clear any cached Google Sign-In data (useful for debugging keychain issues)
    func clearGoogleSignInCache() {
        GIDSignIn.sharedInstance.signOut()
        print("🧹 Cleared Google Sign-In cache")
    }
    
    // Debug method to check Google Sign-In configuration
    func debugGoogleSignInConfig() {
        print("🔍 Google Sign-In Debug Info:")
        print("   - Configuration: \(GIDSignIn.sharedInstance.configuration?.clientID ?? "None")")
        print("   - Has previous sign-in: \(GIDSignIn.sharedInstance.hasPreviousSignIn())")
        print("   - Bundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")")
        
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") {
            print("   - Config file found: ✅")
        } else {
            print("   - Config file found: ❌")
        }
    }
    
    // MARK: - User Profile Management
    
    private func updateUserProfile(user: User, isNewUser: Bool) async {
        guard let db = self.db else { return }
        
        let userRef = db.collection("users").document(user.uid)
        
        var userData: [String: Any] = [
            "email": user.email ?? "",
            "lastLoginAt": FieldValue.serverTimestamp()
        ]
        
        if isNewUser {
            userData["createdAt"] = FieldValue.serverTimestamp()
            userData["tier"] = "free"
        }
        
        if let displayName = user.displayName {
            userData["displayName"] = displayName
        }
        
        do {
            if isNewUser {
                try await userRef.setData(userData)
            } else {
                try await userRef.updateData(userData)
            }
        } catch {
            print("❌ Error updating user profile: \(error)")
        }
    }
    
    // MARK: - Utility Methods
    
    var currentUser: AuthUser? {
        return authState.userProfile?.user
    }
    
    var currentUserTier: UserTier {
        return authState.userProfile?.tier ?? .free
    }
    
    var isSignedIn: Bool {
        return authState.isAuthenticated
    }
}
