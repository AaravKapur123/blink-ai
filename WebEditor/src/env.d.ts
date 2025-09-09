/// <reference types="vite/client" />

declare global {
  interface Window {
    webkit?: any
    ai?: { invoke?: (prompt: string, context?: any, tool?: string) => void }
  }
}

export {}


