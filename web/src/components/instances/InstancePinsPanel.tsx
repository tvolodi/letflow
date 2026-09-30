/** InstancePinsPanel — dependency-version/provenance list for a case (REQ-399)
 *  plus the deliberate "rebind" action (REQ-432).
 *
 *  Mounted inside InstanceDetailPage.tsx alongside AttachmentPanel — same
 *  "one focused panel component per concern, own query, own
 *  QueryStateBoundary" pattern that page already follows. See
 *  lib/letflow/design/req399-instance-pin-provenance.md §4 and
 *  lib/letflow/design/req432-rebind-pins-publish-retire-ui.md §5.
 */
import { useState } from 'react'
import { useInstancePins } from '@/hooks/useInstancePins'
import { useRebindPins } from '@/hooks/useRebindPins'
import { Button } from '@/components/ui/Button'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import type {
  EffectivePin,
  EffectivePinSource,
  EffectivePinKind,
  RebindPinsResponse,
} from '@/types/api'

interface InstancePinsPanelProps {
  instanceId: string
  /** REQ-432: show the Rebind action (caller passes the cosmetic role gate). */
  canRebind?: boolean
  /** REQ-432: rebind is only offered while the case is ACTIVE. */
  instanceActive?: boolean
}

interface PinRow {
  key: string
  pin: EffectivePin
}

// PinResolver's exact four source() values (pin_resolver.ex) — this
// `Record<EffectivePinSource, string>` mapped type makes a missing or extra
// taxonomy key a compile error, structurally enforcing AC4's "no fifth
// bucket invented, no taxonomy value silently dropped."
const SOURCE_LABELS: Record<EffectivePinSource, string> = {
  resolved: 'Chosen automatically',
  override: 'Requested explicitly',
  inherited: 'Inherited from parent case',
  rebound: 'Changed via rebind',
}

const KIND_LABELS: Record<EffectivePinKind, string> = {
  catalog_entry: 'Service',
  module: 'Module',
  variable_schema: 'Variable schema',
}

const REASON_MAX = 1024

const FIELD_STYLE = {
  width: '100%',
  padding: '.45rem .6rem',
  border: '1px solid var(--border-default)',
  borderRadius: 'var(--radius-sm)',
  boxSizing: 'border-box',
} as const

function newIdempotencyKey(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }
  return `rebind-${Date.now()}-${Math.random().toString(16).slice(2)}`
}

function rebindErrorMessage(err: unknown): string {
  const status = (err as { status?: number } | null)?.status
  switch (status) {
    case 404:
      return 'Case not found.'
    case 409:
      return 'This case can no longer be rebound (finished, or being modified by someone else). Refresh and try again.'
    case 422:
      return 'That version is not valid for this dependency, or the reason is missing.'
    case 403:
      return 'You do not have permission to rebind this case.'
    default:
      return 'Failed to rebind dependency.'
  }
}

export function InstancePinsPanel({
  instanceId,
  canRebind = false,
  instanceActive = false,
}: InstancePinsPanelProps) {
  const pinsQuery = useInstancePins(instanceId)
  const rebind = useRebindPins(instanceId)
  const [rebindTarget, setRebindTarget] = useState<EffectivePin | null>(null)
  const [newVersion, setNewVersion] = useState('')
  const [reason, setReason] = useState('')
  const [idempotencyKey, setIdempotencyKey] = useState('')
  const [successMessage, setSuccessMessage] = useState<string | null>(null)

  const showRebind = canRebind && instanceActive

  function openRebind(pin: EffectivePin) {
    rebind.reset()
    setRebindTarget(pin)
    setNewVersion('')
    setReason('')
    // One key per dialog open; a retry from the same open dialog reuses it.
    setIdempotencyKey(newIdempotencyKey())
    setSuccessMessage(null)
  }

  function closeRebind() {
    setRebindTarget(null)
    rebind.reset()
  }

  const trimmedVersion = newVersion.trim()
  const trimmedReason = reason.trim()
  const versionUnchanged = rebindTarget !== null && trimmedVersion === rebindTarget.version
  const canSubmit =
    rebindTarget !== null &&
    trimmedVersion !== '' &&
    !versionUnchanged &&
    trimmedReason !== '' &&
    reason.length <= REASON_MAX

  function submitRebind(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (!rebindTarget || !canSubmit) return
    rebind.mutate(
      {
        body: {
          reason: trimmedReason,
          entries: [{ kind: rebindTarget.kind, ref: rebindTarget.ref, version: trimmedVersion }],
        },
        idempotencyKey,
      },
      {
        onSuccess: (response: RebindPinsResponse) => {
          const change = response.changes[0]
          setSuccessMessage(
            change
              ? `Moved ${change.ref} from ${change.prior_version} to ${change.new_version}`
              : 'No change: already on that version',
          )
          setRebindTarget(null)
        },
      },
    )
  }

  const rendererState: RendererState = pinsQuery.isLoading
    ? 'loading'
    : pinsQuery.isError
      ? classifyError(pinsQuery.error)
      : 'success'

  const pins: EffectivePin[] = pinsQuery.data?.pins ?? []
  const hasPins = pins.length > 0

  const columns: DataTableColumn<PinRow>[] = [
    { id: 'ref', header: 'Dependency', accessor: (row) => row.pin.ref },
    { id: 'kind', header: 'Kind', accessor: (row) => KIND_LABELS[row.pin.kind] },
    { id: 'version', header: 'Version', accessor: (row) => row.pin.version },
    { id: 'source', header: 'How it was set', accessor: (row) => SOURCE_LABELS[row.pin.source] },
    ...(showRebind
      ? [
          {
            id: 'actions',
            header: 'Actions',
            accessor: (row: PinRow) => (
              <Button
                variant="secondary"
                size="sm"
                data-testid={`pin-rebind-btn-${row.key}`}
                onClick={() => openRebind(row.pin)}
              >
                Rebind
              </Button>
            ),
          },
        ]
      : []),
  ]

  const rows: PinRow[] = pins.map((pin) => ({ key: `${pin.kind}:${pin.ref}`, pin }))

  return (
    <section data-testid="instance-pins-panel">
      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void pinsQuery.refetch() }}
        rateLimitRetryAfter={rendererState === 'rate-limit' ? getRetryAfterSeconds(pinsQuery.error) : undefined}
      >
        {hasPins ? (
          <DataTable columns={columns} data={rows} emptyMessage="No dependencies recorded for this case." />
        ) : (
          <p style={{ color: 'var(--text-secondary)' }}>No dependencies recorded for this case.</p>
        )}
      </QueryStateBoundary>

      {successMessage && (
        <p role="status" data-testid="pin-rebind-success" style={{ color: 'var(--text-secondary)' }}>
          {successMessage}
        </p>
      )}

      {rebindTarget && (
        <div
          style={{ position: 'fixed', inset: 0, background: 'var(--surface-overlay)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 50 }}
        >
          <div
            role="dialog"
            aria-label="Rebind dependency"
            data-testid="pin-rebind-dialog"
            style={{ background: 'var(--surface-card)', borderRadius: '8px', padding: '1.5rem', width: '420px', maxHeight: '90vh', overflowY: 'auto' }}
          >
            <h3 style={{ margin: '0 0 1rem' }}>Rebind dependency</h3>
            <form onSubmit={submitRebind}>
              <div style={{ marginBottom: '.5rem', fontSize: '.9rem' }}>
                <div>Dependency: <strong>{rebindTarget.ref}</strong></div>
                <div>Current version: <code>{rebindTarget.version}</code></div>
              </div>
              <label style={{ display: 'block', marginBottom: '.75rem' }}>
                <span style={{ display: 'block', marginBottom: '.25rem', fontWeight: 500 }}>New version</span>
                <input
                  type="text"
                  data-testid="pin-rebind-new-version-input"
                  value={newVersion}
                  onChange={(e) => setNewVersion(e.target.value)}
                  style={FIELD_STYLE}
                />
                {versionUnchanged && (
                  <span style={{ fontSize: '.8rem', color: 'var(--text-secondary)' }}>Choose a different version</span>
                )}
              </label>
              <label style={{ display: 'block', marginBottom: '.75rem' }}>
                <span style={{ display: 'block', marginBottom: '.25rem', fontWeight: 500 }}>Reason</span>
                <textarea
                  data-testid="pin-rebind-reason-input"
                  rows={3}
                  maxLength={REASON_MAX}
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  style={FIELD_STYLE}
                />
                <span style={{ fontSize: '.8rem', color: 'var(--text-secondary)' }}>
                  {reason.length}/{REASON_MAX}
                </span>
              </label>
              {rebind.isError && (
                <div
                  role="alert"
                  data-testid="pin-rebind-error"
                  style={{ padding: '.6rem', background: 'var(--color-error-tint)', border: '1px solid var(--color-error-border)', borderRadius: 'var(--radius-sm)', color: 'var(--color-error-dark)', marginBottom: '.75rem', fontSize: '.85rem' }}
                >
                  {rebindErrorMessage(rebind.error)}
                </div>
              )}
              <div style={{ display: 'flex', gap: '.5rem', justifyContent: 'flex-end' }}>
                <Button variant="secondary" size="sm" data-testid="pin-rebind-cancel" onClick={closeRebind}>
                  Cancel
                </Button>
                <button
                  type="submit"
                  data-testid="pin-rebind-submit"
                  disabled={!canSubmit || rebind.isPending}
                  style={{
                    padding: '.35rem .8rem',
                    border: 'none',
                    borderRadius: 'var(--radius-sm)',
                    background: 'var(--interactive-primary)',
                    color: 'var(--text-inverse)',
                    cursor: canSubmit ? 'pointer' : 'not-allowed',
                    opacity: canSubmit ? 1 : 0.6,
                  }}
                >
                  {rebind.isPending ? 'Rebinding...' : 'Submit rebind'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </section>
  )
}
