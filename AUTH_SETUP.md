# 🔐 Firebase Authentication Setup Guide

## Overview

Your Mac app now includes full Google Authentication powered by Firebase! Here's what's been implemented:

### ✅ What's Done

1. **Authentication Manager** - Complete Firebase Auth integration
2. **Login View** - Beautiful login screen with Google Sign-In and email/password
3. **Settings Popover** - User profile, tier display, and logout functionality  
4. **Authentication Flow** - Seamless integration with your existing app
5. **Persistent Sessions** - Login state persists across app restarts
6. **User Tier System** - Free/Pro/Pro Unlimited tier support from Firestore

### 🎯 Features

- **Google Sign-In** with Firebase Authentication
- **Email/Password** authentication as fallback
- **User Profile Management** with tier display
- **Settings Wheel** in top-right with user info and logout
- **Automatic Firestore Integration** for user data and tiers
- **Persistent Authentication** across app sessions

## 🚀 Setup Instructions

### 1. Add Firebase Dependencies to Xcode

You'll need to add the Firebase SDK to your Xcode project:

1. **Open your Xcode project**
2. **Go to File → Add Package Dependencies**
3. **Add these package URLs:**
   - Firebase: `https://github.com/firebase/firebase-ios-sdk`
   - Google Sign-In: `https://github.com/google/GoogleSignIn-iOS`

4. **Select these products when prompted:**
   - `FirebaseAuth`
   - `FirebaseFirestore` 
   - `GoogleSignIn`

### 2. Update GoogleService-Info.plist

The placeholder `GoogleService-Info.plist` has been created, but you need to update it with your actual Firebase project values:

1. **Download the real GoogleService-Info.plist** from your Firebase Console
2. **Replace the placeholder file** at `UsefulMacApp/GoogleService-Info.plist`
3. **Make sure it's added to your Xcode target**

### 3. Configure URL Schemes (for Google Sign-In)

1. **In Xcode, select your target**
2. **Go to Info tab**
3. **Add a new URL Scheme:**
   - **Identifier**: `GoogleSignIn`
   - **URL Schemes**: Your `REVERSED_CLIENT_ID` from GoogleService-Info.plist

### 4. Firebase Console Setup

Make sure your Firebase project has:

1. **Authentication enabled** with Google and Email/Password providers
2. **Firestore database** with these rules:
   ```javascript
   rules_version = '2';
   service cloud.firestore {
     match /databases/{database}/documents {
       match /users/{userId} {
         allow read, write: if request.auth != null && request.auth.uid == userId;
       }
     }
   }
   ```

3. **Users collection structure:**
   ```
   users/{uid}/
   ├── email: string
   ├── displayName?: string  
   ├── tier: "free" | "pro" | "unlimited"
   ├── createdAt: timestamp
   └── lastLoginAt: timestamp
   ```

## 🎨 UI Components

### LoginView
- Matches your Framer override styling
- Dark theme with glassmorphism effects
- Google Sign-In button with proper branding
- Email/password form with validation
- Loading states and error handling

### SettingsPopover  
- Accessible via gear icon in top-right
- Shows user email, tier badge, and member since date
- Logout functionality with confirmation
- Links to billing portal for Pro/Pro Unlimited users

### Authentication Flow
- Loading screen while Firebase initializes
- Login view when unauthenticated  
- Main app when authenticated
- Permissions view (existing) for new users

## 🔧 Code Structure

### Core Files Added:
- `AuthenticationModels.swift` - Data models and enums
- `AuthenticationManager.swift` - Main auth service class
- `LoginView.swift` - Login/signup interface
- `SettingsPopover.swift` - User settings popup

### Modified Files:
- `ContentView.swift` - Added auth flow and settings button
- `UsefulMacAppApp.swift` - Added auth manager to environment
- `UsefulMacApp.entitlements` - Already had network permissions ✅

## 🎯 User Flow

1. **App Launch** → Firebase initializes and checks auth state
2. **Not Logged In** → Shows login screen with Google + email options
3. **Login Success** → Navigates to permissions (new users) or main app
4. **Main App** → Settings gear appears in top-right toolbar
5. **Settings Click** → Popover shows user info, tier, logout option
6. **App Restart** → Automatically signed in (persistent session)

## 🔐 Security Features

- **Secure token storage** via Firebase Auth
- **Automatic token refresh** 
- **Firestore security rules** protect user data
- **Google OAuth 2.0** for secure authentication
- **No plain text password storage**

## 🎉 Ready to Test!

Your authentication system is now fully integrated! Users will see the login screen on first launch, and can sign in with Google or create an account with email/password. Their login will persist across app restarts, and they can manage their account via the settings popup.

The tier system will automatically sync with your existing Stripe billing setup in Firestore, so Pro and Pro Unlimited users will see their correct tier displayed.

## 🔄 Next Steps

If you want to add additional features:
- Social login providers (Apple, GitHub, etc.)
- Password reset functionality  
- Profile editing
- Account deletion
- Two-factor authentication

The authentication foundation is solid and extensible for any future needs!
