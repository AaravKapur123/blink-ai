//
//  LoginView.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import SwiftUI
import AppKit

struct LoginView: View {
    @StateObject private var authManager = AuthenticationManager.shared
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showError = false
    
    var body: some View {
        ZStack {
            // Background matching your app's dark theme
            Color(red: 0.08, green: 0.08, blue: 0.09)
                .ignoresSafeArea()
            
            loginContent
        }
        .onSubmit {
            if !email.isEmpty && !password.isEmpty {
                handleEmailSignIn()
            }
        }
    }
    
    private var loginContent: some View {
        VStack(spacing: 0) {
            Spacer()
            
            loginCard
            
            Spacer()
            
            footerText
        }
        .padding(.horizontal, 40)
    }
    
    private var loginCard: some View {
        VStack(spacing: 20) {
            headerSection
            googleSignInButton
            dividerSection
            emailPasswordForm
            statusSection
        }
        .frame(maxWidth: 360)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.white)
            
            Text("Sign in to Blink")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
            
            Text("Access your AI assistant across all devices")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 12)
    }
    
    private var googleSignInButton: some View {
        Button(action: handleGoogleSignIn) {
            HStack(spacing: 12) {
                // Google logo asset fallback to globe if missing
                if let gMark = NSImage(named: "GoogleG") {
                    Image(nsImage: gMark)
                        .resizable()
                        .renderingMode(.original)
                        .interpolation(.high)
                        .frame(width: 28, height: 28)
                        .mask(Circle().scale(0.85))
                } else if let nsImage = NSImage(named: "GoogleLogo") {
                    Image(nsImage: nsImage)
                        .resizable()
                        .renderingMode(.original)
                        .interpolation(.high)
                        .frame(width: 28, height: 28)
                        .mask(Circle().scale(0.85))
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.black)
                        .frame(width: 28, height: 28)
                        .mask(Circle().scale(0.85))
                }
                
                Text("Sign in with Google")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white)
            )
            // Removed border overlay for a cleaner look
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
    
    private var dividerSection: some View {
        HStack {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.gray.opacity(0.3))
            
            Text("or")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
            
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.gray.opacity(0.3))
        }
        .padding(.vertical, 8)
    }
    
    private var emailPasswordForm: some View {
        VStack(spacing: 16) {
            emailField
            passwordField
            actionButtons
        }
    }
    
    private var emailField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Email")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            
            TextField("you@example.com", text: $email)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .font(.system(size: 14))
                .foregroundColor(.white)
                .autocorrectionDisabled()
         
        }
    }
    
    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Password")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            
            SecureField("••••••••", text: $password)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .font(.system(size: 14))
                .foregroundColor(.white)
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Sign In Button
            Button(action: handleEmailSignIn) {
                Text(isSignUp ? "Create Account" : "Sign In")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isLoading || email.isEmpty || password.isEmpty)
            
            // Toggle Sign Up/Sign In Button
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isSignUp.toggle() } }) {
                Text(isSignUp ? "Sign In" : "Create Account")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
    }
    
    private var statusSection: some View {
        VStack(spacing: 12) {
            // Error Message
            if showError && !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // Loading Indicator
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    
                    Text("Signing in...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
    
    private var footerText: some View {
        Text("Your data is encrypted and secure")
            .font(.system(size: 11, weight: .regular))
            .foregroundColor(.secondary)
            .padding(.bottom, 32)
    }
    
    // MARK: - Actions
    
    private func handleGoogleSignIn() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isLoading = true
            errorMessage = ""
            showError = false
        }
        
        Task {
            do {
                try await authManager.signInWithGoogle()
            } catch {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isLoading = false
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
        }
    }
    
    private func handleEmailSignIn() {
        guard !email.isEmpty, !password.isEmpty else { return }
        
        withAnimation(.easeInOut(duration: 0.2)) {
            isLoading = true
            errorMessage = ""
            showError = false
        }
        
        Task {
            do {
                if isSignUp {
                    try await authManager.createAccountWithEmail(email, password: password)
                } else {
                    try await authManager.signInWithEmail(email, password: password)
                }
            } catch {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isLoading = false
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
        }
    }
}

#Preview {
    LoginView()
}
