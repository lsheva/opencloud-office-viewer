# office-viewer — backlog

Read-only Office preview for OpenCloud, rendered fully in the browser by
`@silurus/ooxml` (no office server, no WOPI).

Status values: `open`, `blocked`, `wontfix`. Tick an item only when its acceptance
criteria are met — `[x]` means verified on the target instance, not "code written".

## High

- [ ] **Install the CSP override on the Orange Pi**
  - **Priority:** high
  - **Status:** open
  - **Description:** Verified in dev: without a CSP override the app loads but renders
    nothing — OpenCloud's default `script-src` lacks `'wasm-unsafe-eval'` and there is no
    `worker-src`, so `@silurus/ooxml` fails with "Refused to load blob:… worker-src" /
    "Worker error". Copy `csp-override.yaml` to `/etc/opencloud/` and set
    `PROXY_CSP_CONFIG_FILE_OVERRIDE_LOCATION` in a systemd drop-in, then restart. The
    override replaces the whole policy, so re-check it against OpenCloud defaults on
    upgrades.

- [ ] **Deploy `dist/` to the Orange Pi and restart OpenCloud**
  - **Priority:** high
  - **Status:** open
  - **Description:** Nothing has been installed on the device yet; only `pnpm build` has
    been run locally. Build the archive (`pnpm package`) and install it with the installer,
    which targets the documented default `$OC_DATA_DIR/web/assets/apps`
    (`/var/lib/opencloud/...`) unless `APPS_DIR` is set:
    `sudo sh scripts/install.sh release/office-viewer.zip`. Verify that
    `manifest.json` is served from the app path and that `office-viewer` appears in the Web
    app list.

- [ ] **Smoke-test real documents on the device**
  - **Priority:** high
  - **Status:** open
  - **Description:** `samples/` now holds one real fixture per supported extension (docx,
    xlsx, pptx, doc, xls, ppt, odt, ods, odp — Apache POI / ODF Toolkit, already checksummed).
    Upload them with `NODE_TLS_REJECT_UNAUTHORIZED=0 node scripts/seed-samples.mjs`
    (the personal space id is resolved from the Graph API; `OC_SPACE_ID` overrides it), then
    open each from Files and confirm: OOXML and legacy files render, the three ODF files show
    the download fallback, the app is picked as default opener, no `.wasm` 404s behind the
    reverse proxy, and memory stays reasonable while a large deck renders. Remember that
    `pnpm build` only takes effect after `systemctl restart opencloud` — app manifests are
    read at startup.

## Medium

- [ ] **Verify the page/slide sidebar on large documents**
  - **Priority:** medium
  - **Status:** open
  - **Description:** The thumbnail sidebar rasterises pages/slides lazily on intersection,
    one at a time, and caches `ImageBitmap`s. Check a 50+ page docx and a 20+ slide pptx,
    ideally on the Pi: the sidebar must not block scrolling, clicking a thumbnail must land
    on that page, highlighting must track scrolling, and memory must stay bounded. If
    rasterisation is too heavy on ARM, lower `THUMB_WIDTH` or cap the number of thumbnails
    and fall back to number-only entries.

- [ ] **Word text selection highlight is misaligned (PowerPoint is fine)**
  - **Priority:** medium
  - **Status:** open
  - **Description:** Selecting text in a `.docx` highlights the wrong area: the blue run
    rectangles start mid-word, overrun the end of the line, sit slightly lower than the
    glyphs, and a thin stray band appears above the text (observed with `samples/sample.docx`,
    Calibri 11, page 1, sidebar present, around a bold run). Copying still yields the right
    characters — only the highlight geometry is wrong. Enabled via
    `enableTextSelection: true`; the library draws the text layer (`buildDocxTextLayer`) over
    the canvas.

    **PowerPoint selection aligns correctly** (`.pptx` verified). Both viewers use the same
    canvas + absolute text-layer approach, which rules out the shared causes: DPR/zoom
    mismatch, and the sidebar resizing the viewer after mount. That leaves docx-specific
    measurement: run rectangles are computed per wrapped line, and Calibri is normally absent
    on macOS/Linux, so the text-layer measurer and the canvas renderer can disagree on
    advance widths (bold runs especially).

    Next: (1) test a document whose font is installed locally (e.g. Liberation Sans/
    Helvetica) — if the highlight aligns, it is font substitution; (2) compare a single-line
    run against wrapped text on the same page to see whether the drift accumulates per line
    (suggesting per-line offset rather than per-glyph width); (3) report upstream in
    `@silurus/ooxml` with this reproduction, since `buildDocxTextLayer` owns the geometry.
    Workaround until then: none — selection still copies correctly.

- [ ] **ODF (`.odt` / `.ods` / `.odp`) cannot be rendered**
  - **Priority:** medium
  - **Status:** blocked
  - **Description:** `@silurus/ooxml` ships no OpenDocument parser — its exports are only
    `docx`, `xlsx`, `pptx`, `math`, `node`, `tiff`, `three-d`, `chart-ex`, `region-map`.
    The three extensions are registered anyway and `App.vue` shows a "download instead"
    message rather than attempting a parse. Blocked upstream; revisit only if a viable
    WASM ODF renderer appears, otherwise close as `wontfix`.

- [ ] **Verify the Docker dev loop**
  - **Priority:** medium
  - **Status:** open
  - **Description:** The stack itself is now verified (2026-11-10): `config.json` serves
    `office-viewer`, `/assets/apps/office-viewer/**` returns 200 (`.wasm` as
    `application/wasm`), the `seed` service uploads `samples/` into Personal →
    `office-viewer-samples`, and files render. What is still unverified is the iteration loop:
    OpenCloud only reads app manifests at startup, so a rebuild changes the
    `remoteEntry-*.mjs` hash and requires `docker compose restart opencloud` — `build:w`
    alone leaves the browser pointing at a missing entrypoint. Decide whether to accept the
    restart per build, or stabilise the entrypoint filename in the Vite/MF config so watch
    mode becomes usable.

- [ ] **Measure first-load weight on the Pi**
  - **Priority:** medium
  - **Status:** open
  - **Description:** `dist/` is ~19 MB; the render worker is ~2.6 MB, the docx chunk
    ~1.2 MB, and each parser WASM is ~2.0–2.3 MB. Measure cold-open time over LAN for each
    format and decide whether a loading indicator or finer per-format splitting is needed.
    Formats are already dynamic-imported, so any further gain is mostly asset sizing.

## Low

- [ ] **Re-evaluate `optimizeDeps.exclude: ['@silurus/ooxml']`**
  - **Priority:** low
  - **Status:** open
  - **Description:** Added in `vite.config.ts` to dodge a Vite 7 dev-server WASM
    asset-path bug; harmless on Vite 8. Remove it if the dev loop still works without it
    (depends on the Docker dev-loop verification above).

- [ ] **Extract `$gettext` strings into `l10n/translations.json`**
  - **Priority:** low
  - **Status:** open
  - **Description:** UI strings in `App.vue` go through `$gettext`, but
    `l10n/translations.json` is still `{"en": {}}`, so English relies on msgid fallback.
    Add the extracted catalogue (and a `translate` script) if any non-English locale is
    wanted.

- [ ] **Decide a pin policy for the beta toolchain**
  - **Priority:** low
  - **Status:** open
  - **Description:** The stack runs `typescript 7.1.0-beta` (pinned exactly — a
    `^7.1.0-beta` range drifts onto `7.1.0-dev.*` nightlies) and
    `@vue/content-mapper 4.0.0-alpha.3`, which replaces the removed `vue-tsc`. Re-check
    when TS 7.1 reaches stable and when content mappers leave alpha; both are required for
    `pnpm check:types` to keep working.

- [ ] **Exercise the `wasmUrl` fallback**
  - **Priority:** low
  - **Status:** open
  - **Description:** Every viewer accepts a `wasmUrl` option in case the emitted asset
    paths break behind a proxy or CDN. Not implemented or tested in this app; only worth
    doing if the device smoke test shows WASM 404s.

## Not planned

- [ ] **Editing / save round-trip**
  - **Priority:** —
  - **Status:** wontfix
  - **Description:** View-only by design: the app receives `{ resource, url }`
    (`ViewerSlotProps`), not document content, so there is no write path. Reopen only on an
    explicit request, and then it becomes an editor app, not this one.
