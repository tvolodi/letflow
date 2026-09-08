/** useToast — design-system primitive (REQ-275, docs/frontend/design-system.md §7.4)
 *
 *  Module-level store (not React Context) subscribed to via useSyncExternalStore.
 *  A single ToastContainer (web/src/components/ui/Toast.tsx) renders whatever this
 *  store holds; any component may call useToast() to add entries without needing a
 *  <ToastProvider> wrapper.
 */

export type ToastVariant = 'success' | 'error' | 'warning'

export interface ToastOptions {
  description?: string
}

export interface ToastEntry {
  id: string
  variant: ToastVariant
  message: string
  description?: string
  durationMs: number
  createdAt: number
}

export interface UseToastResult {
  success: (message: string, options?: ToastOptions) => void
  error: (message: string, options?: ToastOptions) => void
  warning: (message: string, options?: ToastOptions) => void
}

// Timing table (design §3.4): non-error variants dismiss after 4s, error after 8s.
const DURATION_MS: Record<ToastVariant, number> = {
  success: 4000,
  warning: 4000,
  error: 8000,
}

let entries: ReadonlyArray<ToastEntry> = []
const timeouts = new Map<string, ReturnType<typeof setTimeout>>()
const listeners = new Set<() => void>()

let nextId = 0
function generateId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }
  nextId += 1
  return `toast-${nextId}`
}

function notify(): void {
  listeners.forEach((listener) => listener())
}

function clearTimer(id: string): void {
  const handle = timeouts.get(id)
  if (handle !== undefined) {
    clearTimeout(handle)
    timeouts.delete(id)
  }
}

export function dismissToast(id: string): void {
  clearTimer(id)
  const next = entries.filter((entry) => entry.id !== id)
  if (next.length !== entries.length) {
    entries = next
    notify()
  }
}

export function clearAllToasts(): void {
  timeouts.forEach((handle) => clearTimeout(handle))
  timeouts.clear()
  entries = []
  notify()
}

function addToast(variant: ToastVariant, message: string, options?: ToastOptions): void {
  const id = generateId()
  const entry: ToastEntry = {
    id,
    variant,
    message,
    description: options?.description,
    durationMs: DURATION_MS[variant],
    createdAt: Date.now(),
  }

  let next = [entry, ...entries]
  if (next.length > 4) {
    const dropped = next.slice(4)
    dropped.forEach((droppedEntry) => clearTimer(droppedEntry.id))
    next = next.slice(0, 4)
  }
  entries = next

  const handle = setTimeout(() => dismissToast(id), entry.durationMs)
  timeouts.set(id, handle)

  notify()
}

export function subscribeToasts(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function getToastSnapshot(): ReadonlyArray<ToastEntry> {
  return entries
}

export function useToast(): UseToastResult {
  return {
    success: (message, options) => addToast('success', message, options),
    error: (message, options) => addToast('error', message, options),
    warning: (message, options) => addToast('warning', message, options),
  }
}
