# office-viewer

A read-only OpenCloud Web app that renders Office documents **entirely in the browser**, with **no office server** (no Collabora/ONLYOFFICE, no WOPI). Rendering is done client-side by [`@silurus/ooxml`](https://www.npmjs.com/package/@silurus/ooxml) (Rust→WASM parsers + Canvas renderers).

Scaffolded from the official [`opencloud-eu/web-app-skeleton`](https://github.com/opencloud-eu/web-app-skeleton) template, using the file-type viewer pattern of [`web-app-json-viewer`](https://github.com/opencloud-eu/web-extensions/tree/main/packages/web-app-json-viewer).

## Supported formats

| Extension                | Renderer                                             | Status                            |
| ------------------------ | ---------------------------------------------------- | --------------------------------- |
| `.docx`                  | `@silurus/ooxml/docx` → `DocxScrollViewer`           | ✅ rendered                       |
| `.xlsx`                  | `@silurus/ooxml/xlsx` → `XlsxViewer`                 | ✅ rendered                       |
| `.pptx`                  | `@silurus/ooxml/pptx` → `PptxScrollViewer`           | ✅ rendered                       |
| `.doc`                   | `@silurus/ooxml-legacy-office/doc` (via DOCX viewer) | ✅ rendered (experimental reader) |
| `.xls`                   | `@silurus/ooxml-legacy-office/xls` (via XLSX viewer) | ✅ rendered (experimental reader) |
| `.ppt`                   | `@silurus/ooxml-legacy-office/ppt` (via PPTX viewer) | ✅ rendered (experimental reader) |
| `.odt` / `.ods` / `.odp` | —                                                    | ⚠️ registered, **not rendered**   |

**About ODF:** `@silurus/ooxml` intentionally targets Office Open XML plus legacy binary Office; it has **no OpenDocument renderer** (no `opendocument`/`odf` export in the published package). The `odt/ods/odp` extensions are registered so those files route to this app, but `App.vue` shows a clear "download instead" message rather than attempting a parse. To actually render ODF you'd need a different library (e.g. a LibreOffice-WASM build) — out of scope here.

**PDF** is untouched — the browser renders it natively via the existing `pdf-viewer` app.

## How it works

- `src/index.ts` registers the extensions in `appInfo.extensions`; OpenCloud routes matching files to this app.
- `src/App.vue` receives `{ resource, url }` (a signed WebDAV URL), picks the viewer by extension, dynamic-imports only the needed `@silurus/ooxml` entry (and the legacy add-on for `.doc/.xls/.ppt`), mounts the viewer on a container, and calls `load(url)`.
- Word and PowerPoint get a thumbnail sidebar: `DocxDocument` / `PptxPresentation` are loaded once and shared with `DocxScrollViewer.fromDocument()` / `PptxScrollViewer.fromPresentation()`; thumbnails are rasterised lazily (IntersectionObserver, one at a time) via `renderPageToBitmap()` / `renderSlideToBitmap()`, and clicking one calls `scrollToPage()` / `scrollToSlide()`.
- Because the `collaboration` WOPI service is not enabled on this instance, this app becomes the **default** opener for those extensions.

## Layout

```
office-viewer/
├── package.json
├── vite.config.ts
├── tsconfig.json
├── BACKLOG.md               # open work, priorities, status
├── csp-override.yaml        # CSP that allows WASM + blob: workers
├── docker-compose.yml       # throwaway OpenCloud + sample seeder
├── l10n/translations.json
├── samples/                 # one real fixture per supported format
│   └── README.md            # provenance, checksums, expected results
├── scripts/
│   └── seed-samples.mjs     # uploads samples/ over WebDAV
└── src/
    ├── env.d.ts             # vite/client + design-system `GlobalComponents`
    ├── index.ts             # defineWebApplication + appInfo.extensions
    └── App.vue              # container + @silurus/ooxml viewers
```

## Type checking

Vue SFC type-checking uses the TypeScript 7.1 **content mapper** mechanism instead of
`vue-tsc` (which crashes on TS 7 because `typescript/lib/tsc` is no longer an exported
subpath, and is being deprecated in favour of this API):

```bash
pnpm check:types    # tsc --runExternalCode
```

`tsconfig.json` declares the mapper (`contentMappers`, sibling of `compilerOptions`),
and `src/env.d.ts` pulls in `@opencloud-eu/design-system/types` so the template checker
knows the `oc-*` global components that the host app provides at runtime.

## Sample documents

`samples/` holds one real, unmodified fixture per supported extension (Apache POI and
ODF Toolkit, both Apache-2.0) so a broken preview is obviously the viewer's fault:
`docx`/`xlsx`/`pptx`, legacy `doc`/`xls`/`ppt`, and `odt`/`ods`/`odp` to exercise the
ODF fallback. Provenance and checksums are in `samples/README.md`.

They are uploaded into an instance over WebDAV rather than bind-mounted, because
OpenCloud's PosixFS driver keeps per-file metadata in extended attributes and only
assimilates out-of-band files at startup; a read-only mount cannot do that.

- Docker dev stack: the `seed` service does it automatically after `docker compose up`.
- Any instance: `NODE_TLS_REJECT_UNAUTHORIZED=0 node scripts/seed-samples.mjs`
  (`OC_URL`/`OC_USER`/`OC_PASSWORD`/`OC_SPACE_ID` override the defaults).

The files land in **Personal → `office-viewer-samples`**.

## Dependencies (current)

- `@silurus/ooxml` **0.89.8** and `@silurus/ooxml-legacy-office` **0.89.8** — pinned exactly; the legacy add-on requires identical versions.
- `@opencloud-eu/{extension-sdk,tsconfig,web-client,web-pkg,design-system}` **^8.2.1** — matches OpenCloud 9.0.x's Web (8.2.1). `design-system` is a dev dependency purely for its `GlobalComponents` types.
- Tooling: `vite ^8.3.7`, `vue ^3.5.45`, `vue-router ^5.4.0`, `vue3-gettext ^4.0.1`, and the latest TypeScript: **`typescript 7.1.0-beta`** (pinned to the `beta` tag — a `^7.1.0-beta` range would drift onto nightly `7.1.0-dev.*` builds) + **`@vue/content-mapper ^4.0.0-alpha.3`**.
- `vue-tsc` is intentionally **not** installed: it hard-crashes with TS 7 (`ERR_PACKAGE_PATH_NOT_EXPORTED: typescript/lib/tsc`).

## Build

```bash
cd office-viewer
corepack enable
pnpm install
pnpm check:types    # optional: TS 7.1 content mapper over .vue
pnpm build          # one-off -> dist/
pnpm build:w        # watch mode
pnpm package        # build + release/office-viewer.zip
```

`dist/` contains `manifest.json`, the module-federation `remoteEntry*.mjs`, JS chunks, and the `@silurus/ooxml` `.wasm` parser assets.

## Test locally with a throwaway OpenCloud (Docker)

The included `docker-compose.yml` runs an OpenCloud server and mounts `./dist` as an installed app:

```bash
pnpm install
pnpm build
docker compose up
```

Open **https://localhost:9200** and log in as `admin` / `admin`, then open **Personal → `office-viewer-samples`** — the `seed` service uploads `samples/` there once the server is up. While the stack runs, `pnpm build:w` rebuilds into the mounted `dist/`; reload the browser to pick up changes.

> **Restart after rebuilding.** OpenCloud reads app manifests from `WEB_ASSET_APPS_PATH` at startup, so `dist/manifest.json` is only re-read on `docker compose restart opencloud`. A browser reload alone will request the previous `remoteEntry-*.mjs` and 404. Rebuild → restart the container → hard-reload the browser.

> If `host.docker.internal` doesn't resolve in your browser (non-Docker-Desktop setups), add `127.0.0.1 host.docker.internal` to `/etc/hosts`. OrbStack/Docker Desktop usually resolve it already.

## CSP requirement (dev and production)

OpenCloud's default Content-Security-Policy blocks what `@silurus/ooxml` needs:
`script-src 'self' 'unsafe-inline'` has no `'wasm-unsafe-eval'`, and there is no
`worker-src`, so a `blob:` worker is refused and every format fails with
`Refused to load blob:… worker-src` → `Error: Worker error`.

`csp-override.yaml` restores the complete OpenCloud default policy with exactly two
additions (`script-src` gains `'wasm-unsafe-eval'`, `worker-src 'self' blob:` added).
Point `PROXY_CSP_CONFIG_FILE_OVERRIDE_LOCATION` at it — `docker-compose.yml` already
does. Note the override **replaces** the whole policy rather than merging per
directive, so keep the file in sync when OpenCloud's defaults change. This applies to
the bare-metal Orange Pi install too.

## Install

Works on any OpenCloud 9 instance. The app is a static bundle — nothing runs server-side and
no office service is involved. Admins install it by copying a folder into the apps directory
and restarting (see the
[OpenCloud docs](https://docs.opencloud.eu/docs/admin/configuration/web-applications)).

> Releases are published from
> [lsheva/opencloud-office-viewer](https://github.com/lsheva/opencloud-office-viewer).

### One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/lsheva/opencloud-office-viewer/main/scripts/install.sh | sh
```

No arguments, no `sudo` prefix: the script defaults to the latest release archive, asks for
sudo once, installs the app **and** the CSP override (plus the systemd drop-in pointing at
it), and restarts OpenCloud. If sudo is unavailable it prints the equivalent commands to
run as root instead.

| Variable | Effect |
| --- | --- |
| `APPS_DIR` | override the detected apps directory |
| `WITH_CSP=0` | skip the CSP override (it is installed by default) |
| `NO_RESTART=1` | skip `systemctl restart opencloud` |
| `CSP_FILE` | use a local CSP file instead of downloading `csp-override.yaml` |

The apps directory is detected, not assumed: the running service's environment is read
(`WEB_ASSET_APPS_PATH`, then `OC_DATA_DIR`/`OC_BASE_DATA_PATH`), then any existing
`*/web/assets/apps` directory, and only then OpenCloud's documented default
(`/var/lib/opencloud/web/assets/apps`). Check the result before installing:

```bash
curl -fsSL https://raw.githubusercontent.com/lsheva/opencloud-office-viewer/main/scripts/install.sh \
  | sh -s -- --detect
```

### Manually

```bash
curl -fsSL -o office-viewer.zip \
  https://github.com/lsheva/opencloud-office-viewer/releases/latest/download/office-viewer.zip
sh scripts/install.sh office-viewer.zip      # WITH_CSP=0 to skip the CSP step
```

`office-viewer.zip` is a stable asset name that always points at the newest build; a
versioned `office-viewer-<version>.zip` is published alongside it.

### From source

```bash
pnpm install && pnpm package          # -> release/office-viewer.zip
sh scripts/install.sh release/office-viewer.zip
```

### CSP override (installed by default)

Without it the app loads but renders nothing: OpenCloud's default `script-src` has no
`'wasm-unsafe-eval'` and there is no `worker-src`, so the library's `blob:` worker is
refused. The installer handles this; to do it by hand:

```bash
sudo cp csp-override.yaml /etc/opencloud/csp-override.yaml
```

```ini
# /etc/systemd/system/opencloud.service.d/csp.conf
[Service]
Environment=PROXY_CSP_CONFIG_FILE_OVERRIDE_LOCATION=/etc/opencloud/csp-override.yaml
```

Apps are served from `WEB_ASSET_APPS_PATH`, which defaults to
`$OC_DATA_DIR/web/assets/apps` (`/var/lib/opencloud/web/assets/apps`). Only add an
override if your data directory is somewhere else:

```ini
Environment=WEB_ASSET_APPS_PATH=/custom/path/web/assets/apps
```

The restart in both install paths is mandatory: app manifests are read at startup, so a
copied bundle stays invisible until OpenCloud restarts. Once it does, the app appears as
**`office-viewer`** and becomes the default opener for `.docx/.xlsx/.pptx/.doc/.xls/.ppt`
(the built-in `collaboration` service is what would otherwise claim those files).

## Releasing

```bash
pnpm version patch        # or minor/major; writes package.json and creates the tag
git push --follow-tags
```

The `release` workflow builds on the tag and attaches two assets to the GitHub release:
`office-viewer.zip` (stable name, used by the install one-liner above) and
`office-viewer-<version>.zip`. `pnpm package` produces the same archive locally.

Listing it in the OpenCloud app store is a one-line PR to
[`opencloud-eu/awesome-apps`](https://github.com/opencloud-eu/awesome-apps), under
_Viewers & Editors_:

```md
- [office-viewer](https://github.com/lsheva/opencloud-office-viewer) - Preview .docx/.xlsx/.pptx (and legacy .doc/.xls/.ppt) fully in the browser; no office server required.
```

## Caveats

- **Library maturity.** `@silurus/ooxml` is young (2026) and its author describes the code as entirely AI-generated. It aims for high fidelity and hardens against untrusted input (canvas-only rendering, bounded resource limits, no network by default), but validate against your real documents.
- **Legacy Office is experimental.** The `.doc/.xls/.ppt` readers are narrow and reject unsupported content rather than showing a partial document. `@silurus/ooxml` and `@silurus/ooxml-legacy-office` must be the **same exact version**.
- **WASM assets.** The library loads `.wasm` files via `new URL(..., import.meta.url)` next to the JS. The build emits them into `dist/`; copy the whole tree. If they fail to load, each viewer accepts a `wasmUrl` option.
- **Vite.** `vite.config.ts` sets `optimizeDeps.exclude: ['@silurus/ooxml']` to avoid a Vite 7 dev-server asset-path bug; production builds are unaffected.
- **No editing.** View-only by design; no save/round-trip path.
