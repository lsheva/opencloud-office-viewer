<template>
  <div class="office-viewer">
    <aside v-if="pageCount > 0" class="office-viewer__sidebar" :aria-label="$gettext('Pages')">
      <button
        v-for="index in pageCount"
        :key="index"
        type="button"
        class="office-viewer__thumb"
        :class="{ 'office-viewer__thumb--active': activePage === index - 1 }"
        :aria-label="labelFor(index - 1)"
        :aria-current="activePage === index - 1 ? 'page' : undefined"
        @click="goTo(index - 1)"
      >
        <canvas
          class="office-viewer__thumb-canvas"
          :ref="(el) => registerThumb(index - 1, el)"
        />
        <span class="office-viewer__thumb-label" v-text="index" />
      </button>
    </aside>

    <div v-show="!error" ref="containerRef" class="office-viewer__surface" />

    <div v-if="error" class="office-viewer__error">
      <p class="office-viewer__error-text" v-text="error" />
      <!-- OcButton has no `download` prop; `resource.downloadURL` already carries the
           download disposition, so a plain anchor button is enough. -->
      <oc-button type="a" appearance="filled" :href="downloadUrl">
        <oc-icon name="download" fill-type="line" />
        <span>{{ $gettext('Download file') }}</span>
      </oc-button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import type { PropType } from 'vue'
import type { Resource } from '@opencloud-eu/web-client'
import { useGettext } from 'vue3-gettext'

// Runtime prop declaration (not `defineProps<ImportedType>()`): resolving an imported
// type in defineProps needs fs access that the extension-sdk's Vue plugin doesn't
// provide under Vite 8/rolldown. Use the same shape as AppWrapper's ViewerSlotProps.
const props = defineProps({
  resource: { type: Object as PropType<Resource>, required: true },
  url: { type: String, required: true }
})

type ViewerKind = 'docx' | 'doc' | 'xlsx' | 'xls' | 'pptx' | 'ppt' | 'odt' | 'ods' | 'odp'
type Destroyable = { destroy: () => void }
type ThumbnailRenderer = (index: number, width: number) => Promise<ImageBitmap>

const THUMB_WIDTH = 132

const { $gettext } = useGettext()

const containerRef = ref<HTMLElement>()
const error = ref<string>()
const pageCount = ref(0)
const activePage = ref(0)
const unit = ref<'page' | 'slide'>('page')

// `url` is the inline-disposition URL the viewers fetch; the download link has to
// use the attachment URL, which the Resource already exposes.
const downloadUrl = computed(() => props.resource.downloadURL || props.url)

const labelFor = (index: number) =>
  unit.value === 'slide'
    ? $gettext('Slide %{ page }', { page: String(index + 1) })
    : $gettext('Page %{ page }', { page: String(index + 1) })

let viewer: (Destroyable & { relayout?: () => void }) | undefined
let documentHandle: Destroyable | undefined
let goto: ((index: number) => void) | undefined
let renderThumb: ThumbnailRenderer | undefined

// --- thumbnails -------------------------------------------------------------
// Rendered lazily: a page/slide is only rasterised once its button scrolls into
// view, one at a time, so a 200 page document doesn't peg the CPU up front.
const canvases = new Map<number, HTMLCanvasElement>()
const canvasIndex = new WeakMap<HTMLCanvasElement, number>()
let bitmaps = new Map<number, ImageBitmap>()
let queue: number[] = []
let draining = false
let thumbObserver: IntersectionObserver | undefined

const drawThumb = (index: number) => {
  const canvas = canvases.get(index)
  const bitmap = bitmaps.get(index)
  if (!canvas || !bitmap) {
    return
  }
  canvas.width = bitmap.width
  canvas.height = bitmap.height
  canvas.getContext('2d')?.drawImage(bitmap, 0, 0)
}

const drainThumbs = async () => {
  if (draining) {
    return
  }
  draining = true
  try {
    while (queue.length) {
      const index = queue.shift() as number
      // Skip entries that stopped being rendered while queued (view reset, viewer swapped).
      if (!renderThumb || !canvases.has(index)) {
        continue
      }
      try {
        bitmaps.set(index, await renderThumb(index, THUMB_WIDTH))
        drawThumb(index)
      } catch {
        // Leave this entry with its number only; a failed thumbnail is not fatal.
      }
      await new Promise((resolve) => setTimeout(resolve, 0))
    }
  } finally {
    draining = false
  }
}

const enqueueThumb = (index: number) => {
  if (!queue.includes(index)) {
    queue.push(index)
  }
  void drainThumbs()
}

const registerThumb = (index: number, element: unknown) => {
  if (!element) {
    canvases.delete(index)
    return
  }
  const canvas = element as HTMLCanvasElement
  canvases.set(index, canvas)
  canvasIndex.set(canvas, index)

  if (bitmaps.has(index)) {
    drawThumb(index)
    return
  }
  if (thumbObserver) {
    thumbObserver.observe(canvas)
  } else {
    enqueueThumb(index)
  }
}

const createThumbObserver = () => {
  if (typeof IntersectionObserver === 'undefined') {
    return
  }
  thumbObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) {
        continue
      }
      thumbObserver?.unobserve(entry.target)
      const index = canvasIndex.get(entry.target as HTMLCanvasElement)
      if (index !== undefined) {
        enqueueThumb(index)
      }
    }
  })
}

const resetThumbs = () => {
  thumbObserver?.disconnect()
  thumbObserver = undefined
  queue = []
  bitmaps.forEach((bitmap) => bitmap.close())
  bitmaps = new Map()
  canvases.clear()
  renderThumb = undefined
  goto = undefined
  pageCount.value = 0
  activePage.value = 0
}

// --- document loading -------------------------------------------------------
const kind = (): ViewerKind | undefined => {
  const name = props.resource.name || ''
  const ext = (props.resource.extension || name.split('.').pop() || '').toLowerCase()
  switch (ext) {
    case 'docx':
    case 'doc':
    case 'xlsx':
    case 'xls':
    case 'pptx':
    case 'ppt':
    case 'odt':
    case 'ods':
    case 'odp':
      return ext
    default:
      return undefined
  }
}

const destroyViewer = () => {
  try {
    viewer?.destroy()
  } catch {
    // ignore teardown errors
  }
  viewer = undefined
  try {
    documentHandle?.destroy()
  } catch {
    // ignore teardown errors
  }
  documentHandle = undefined
}

const goTo = (index: number) => {
  activePage.value = index
  goto?.(index)
}

const setActive = (index: number) => {
  activePage.value = index
}

const load = async () => {
  destroyViewer()
  resetThumbs()
  error.value = undefined

  const container = containerRef.value
  if (!container) {
    return
  }
  container.replaceChildren()
  createThumbObserver()

  const type = kind()
  try {
    switch (type) {
      case 'docx':
      case 'doc': {
        const { DocxDocument, DocxScrollViewer } = await import('@silurus/ooxml/docx')
        unit.value = 'page'
        const doc =
          type === 'doc'
            ? await DocxDocument.load(props.url, {
                legacyDoc: (await import('@silurus/ooxml-legacy-office/doc')).legacyDoc
              })
            : await DocxDocument.load(props.url)
        documentHandle = doc

        const scrollViewer = DocxScrollViewer.fromDocument(container, doc, {
          // Text layer on top of the canvas: enables native selection + copy.
          enableTextSelection: true,
          onVisiblePageChange: (top: number) => setActive(top),
          onError: (err: Error) => console.error('[office-viewer] page render failed', err)
        })
        viewer = scrollViewer
        goto = (index) => scrollViewer.scrollToPage(index, { behavior: 'smooth' })
        renderThumb = (index, width) => doc.renderPageToBitmap(index, { width })
        pageCount.value = doc.pageCount

        // Layout may still be progressive: refresh the count once it settles.
        void doc
          .waitUntilLayoutComplete()
          .then(() => {
            pageCount.value = doc.pageCount
          })
          .catch(() => {
            // keep the count from load()
          })
        break
      }
      case 'pptx':
      case 'ppt': {
        const { PptxPresentation, PptxScrollViewer } = await import('@silurus/ooxml/pptx')
        unit.value = 'slide'
        const presentation =
          type === 'ppt'
            ? await PptxPresentation.load(props.url, {
                legacyPpt: (await import('@silurus/ooxml-legacy-office/ppt')).legacyPpt
              })
            : await PptxPresentation.load(props.url)
        documentHandle = presentation

        const scrollViewer = PptxScrollViewer.fromPresentation(container, presentation, {
          enableTextSelection: true,
          onVisibleSlideChange: (top: number) => setActive(top),
          onError: (err: Error) => console.error('[office-viewer] slide render failed', err)
        })
        viewer = scrollViewer
        goto = (index) => scrollViewer.scrollToSlide(index, { behavior: 'smooth' })
        renderThumb = (index, width) => presentation.renderSlideToBitmap(index, { width })
        pageCount.value = presentation.slideCount

        void presentation
          .waitUntilLayoutComplete()
          .then(() => {
            pageCount.value = presentation.slideCount
          })
          .catch(() => {
            // keep the count from load()
          })
        break
      }
      case 'xlsx':
      case 'xls': {
        const { XlsxViewer } = await import('@silurus/ooxml/xlsx')
        const instance =
          type === 'xls'
            ? new XlsxViewer(container, {
                legacyXls: (await import('@silurus/ooxml-legacy-office/xls')).legacyXls
              })
            : new XlsxViewer(container)
        viewer = instance
        await instance.load(props.url)
        break
      }
      case 'odt':
      case 'ods':
      case 'odp':
        // @silurus/ooxml intentionally scopes to OOXML + legacy binary Office and does
        // not implement OpenDocument. Surface that clearly instead of a parse error.
        error.value = $gettext(
          'Preview is not available for OpenDocument (ODF) files yet. Download the file to open it.'
        )
        break
      default:
        error.value = $gettext('This file type cannot be previewed.')
    }

    // The sidebar mounts after `pageCount` changes, which resizes the canvas host.
    await nextTick()
    try {
      viewer?.relayout?.()
    } catch {
      // relayout is best-effort
    }
  } catch (e) {
    // Parsing/rendering can fail for corrupt, encrypted or unsupported content.
    console.error('[office-viewer] failed to render document', e)
    destroyViewer()
    resetThumbs()
    error.value = $gettext('This document could not be displayed.')
  }
}

onMounted(load)
watch(() => props.url, load)
onBeforeUnmount(() => {
  destroyViewer()
  resetThumbs()
})
</script>

<style scoped>
.office-viewer {
  position: relative;
  display: flex;
  width: 100%;
  height: 100%;
  overflow: hidden;
}

.office-viewer__sidebar {
  flex: 0 0 168px;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding: 0.5rem;
  overflow-y: auto;
  overflow-x: hidden;
  background: var(--oc-role-surface-container-low, rgba(127, 127, 127, 0.08));
  border-right: 1px solid var(--oc-role-outline-variant, rgba(127, 127, 127, 0.25));
}

.office-viewer__thumb {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.25rem;
  padding: 0.25rem;
  border: 2px solid transparent;
  border-radius: 4px;
  background: none;
  color: inherit;
  cursor: pointer;
}

.office-viewer__thumb:hover {
  border-color: var(--oc-role-outline-variant, rgba(127, 127, 127, 0.4));
}

.office-viewer__thumb--active {
  border-color: var(--oc-role-primary, #0d6efd);
}

.office-viewer__thumb-canvas {
  display: block;
  width: 100%;
  height: auto;
  min-height: 4.5rem;
  border-radius: 2px;
  background: #fff;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3);
}

.office-viewer__thumb-label {
  font-size: 0.75rem;
  line-height: 1;
  opacity: 0.8;
}

.office-viewer__surface {
  position: relative;
  flex: 1 1 auto;
  min-width: 0;
  height: 100%;
  overflow: hidden;
}

.office-viewer__error {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 1rem;
  padding: 2rem;
  text-align: center;
  color: var(--oc-role-on-surface, inherit);
}

.office-viewer__error-text {
  font-size: 1.125rem;
  max-width: 32rem;
}
</style>
