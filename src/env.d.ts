/// <reference types="vite/client" />

// Pulls in @opencloud-eu/design-system's `GlobalComponents` augmentation so the
// template type-checker knows the `oc-*` components (provided at runtime by the
// host app). The `types` subpath export exists for exactly this purpose.
import '@opencloud-eu/design-system/types'
