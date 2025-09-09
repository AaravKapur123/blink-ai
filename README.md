# AI Assistant Mac App

A groundbreaking Mac AI assistant app powered by GPT-4o that combines regular chat functionality with innovative screen-to-text generation.

## Features

### Regular Chat
- Beautiful, modern chatbot interface
- Direct integration with GPT-4o
- Real-time conversations with AI

### Revolutionary Screen-to-Text Feature
- **Global Keyboard Shortcut**: Press `Cmd+Shift+Space` anywhere on your Mac
- **Intelligent Analysis**: The AI automatically captures your screen and analyzes the context around your cursor
- **Smart Response Generation**: GPT-4o understands what you need help with and types the answer directly where your cursor is
- **Fallback Handling**: If the AI can't determine what to respond, it types "Try Again"

## How It Works

1. **First Launch**: The app will request necessary permissions (Accessibility and Screen Recording)
2. **Regular Use**: Open the app to chat normally with GPT-4o
3. **Magic Feature**: While working anywhere on your Mac, press `Cmd+Shift+Space` and the AI will:
   - Take a screenshot
   - Analyze what you're working on
   - Generate an appropriate response
   - Type it directly where your cursor is

## Use Cases

- **Homework Help**: Working on an assignment? Press the shortcut and get instant help
- **Code Assistance**: Stuck on a programming problem? Get immediate solutions
- **Writing Support**: Need help with writing? Get suggestions typed right where you need them
- **General Questions**: Any question or task can be solved instantly without switching apps

## Installation

1. Download the `UsefulMacApp.app` from this repository
2. Move it to your Applications folder
3. Launch the app and grant the requested permissions
4. Start chatting or use the global shortcut anywhere!

## Requirements

- macOS 15.2 or later
- Internet connection for GPT-4o API access

## Privacy & Security

- The app only captures screenshots when you explicitly trigger the shortcut
- All data is sent securely to OpenAI's servers
- No persistent storage of your screenshots or conversations

## Technical Details

- Built with Swift and SwiftUI
- Uses GPT-4o for intelligent responses
- Implements Carbon Events for global keyboard shortcuts
- Uses CoreGraphics for screen capture and text input simulation

---

*This is the future of AI assistance - contextual, instant, and seamlessly integrated into your workflow.*
