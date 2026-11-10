import { defineConfig } from '@opencloud-eu/extension-sdk'

export default defineConfig({
  name: 'office-viewer',
  // @silurus/ooxml ships ESM + .wasm assets referenced via `new URL(..., import.meta.url)`.
  // Vite 8 handles that out of the box; excluding it from dep pre-bundling avoids the
  // asset-path rewrite bug that affects the Vite 7 dev server (production builds are fine).
  optimizeDeps: {
    exclude: ['@silurus/ooxml']
  }
})
