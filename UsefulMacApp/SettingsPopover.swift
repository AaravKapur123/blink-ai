//
//  SettingsPopover.swift
//  UsefulMacApp
//
//  Created by Aarav Kapur on 8/20/25.
//

import SwiftUI

struct SettingsButton: View {
    @State private var showSettings = false
    
    var body: some View {
        Button(action: { withAnimation { showSettings.toggle() } }) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSettings, arrowEdge: .top) {
            SettingsPopover()
        }
    }
}

struct SettingsPopover: View {
    @StateObject private var authManager = AuthenticationManager.shared
    @State private var isSigningOut = false
    @State private var showSignOutConfirmation = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Account")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Close button can be handled by clicking outside
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            // User Info Section
            if let userProfile = authManager.authState.userProfile {
                VStack(alignment: .leading, spacing: 12) {
                    // User Email
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Signed in as")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Text(userProfile.user.email ?? "Unknown")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    // User Tier
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plan")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 8) {
                            // Tier badge
                            HStack(spacing: 4) {
                                Image(systemName: tierIcon(for: userProfile.tier))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(tierColor(for: userProfile.tier))
                                
                                Text(userProfile.tier.displayName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.primary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(tierColor(for: userProfile.tier).opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(tierColor(for: userProfile.tier).opacity(0.3), lineWidth: 1)
                            )
                            
                            Spacer()
                        }
                    }
                    
                    // Account created date (if available)
                    if let createdAt = userProfile.createdAt {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Member since")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            Text(formatDate(createdAt))
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(.primary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                Divider()
                    .background(Color.white.opacity(0.1))
            }
            
            // Actions Section
            VStack(spacing: 0) {
                // Manage Subscription: show for all signed-in users
                if authManager.authState.isAuthenticated {
                    Button(action: handleManageSubscription) {
                        HStack(spacing: 10) {
                            Image(systemName: "creditcard.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.blue)
                                .frame(width: 16)
                            
                            Text("Manage Subscription")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        // Add subtle hover effect if desired
                    }
                    
                    Divider()
                        .background(Color.white.opacity(0.1))
                }
                
                // Sign Out Button
                Button(action: { showSignOutConfirmation = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                            .frame(width: 16)
                        
                        Text("Sign Out")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                        
                        Spacer()
                        
                        if isSigningOut {
                            ProgressView()
                                .scaleEffect(0.6)
                                .progressViewStyle(CircularProgressViewStyle(tint: .red))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSigningOut)
                .confirmationDialog(
                    "Sign Out",
                    isPresented: $showSignOutConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Sign Out", role: .destructive) {
                        handleSignOut()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Are you sure you want to sign out?")
                }
            }
            
            // Footer
            VStack(spacing: 8) {
                Divider()
                    .background(Color.white.opacity(0.1))
                
                Text("Blink AI Assistant")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
    
    // MARK: - Helper Methods
    
    private func tierIcon(for tier: UserTier) -> String {
        switch tier {
        case .free:
            return "person.circle"
        case .pro:
            return "star.fill"
        case .unlimited:
            return "crown.fill"
        }
    }
    
    private func tierColor(for tier: UserTier) -> Color {
        switch tier {
        case .free:
            return .gray
        case .pro:
            return .blue
        case .unlimited:
            return .purple
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    // MARK: - Actions
    
    private func handleManageSubscription() {
        // Open Blink AI website
        if let url = URL(string: "https://blinkapp.ai") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func handleSignOut() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSigningOut = true
        }
        
        Task {
            do {
                try await authManager.signOut()
            } catch {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSigningOut = false
                    }
                    // Handle error - maybe show an alert
                    print("❌ Sign out error: \(error)")
                }
            }
        }
    }
}

#Preview {
    SettingsPopover()
        .background(Color.black.ignoresSafeArea())
}
