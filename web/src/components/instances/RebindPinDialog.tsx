/** RebindPinDialog — operator-driven pin rebind for a single dependency
 *  (REQ-078/PIN-05, operator UI: REQ-432 design §3.4).
 *
 *  Same modal-with-focus-trap shape as CancelInstanceDialog.tsx, reused
 *  rather than reinvented. Rebinds ONE pin at a time — the row the operator
 *  clicked "Rebind" on in InstancePinsPanel. The backend's own `entries`
 *  array supports multiple pins per call, but no acceptance criterion or
 *  named e2e scenario for REQ-432 exercises a multi-pin rebind in one call,
 *  so this dialog does not build a multi-select UI for it (design §3.4 —
 *  a stated scope choice, not a silently dropped one).
 */
import { useEffect, useRef, useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { instancesApi } from '@/api/instances'
import type { ApiError, EffectivePin, RebindPinsResult } from '@/types/api'

export interface RebindPinDialogProps {
  open: boolean
  instanceId: string
  pin: EffectivePin | null
  onClose: () => void
  onSuccess: (result: RebindPinsResult) => void
}

const REASON_MAX_LENGTH = 1024

export function RebindPinDialog({ open, instanceId, pin, onClose, onSuccess }: RebindPinDialogProps) {
  const [targetVersion, setTargetVersion] = useState('')
  const [reason, setReason] = useState('')
  const dialogRef = useRef<HTMLDivElement | null>(null)
  const firstFocusableRef = useRef<HTMLButtonElement | null>(null)

  const mutation = useMutation({
    mutationFn: () => {
      if (!pin) throw new Error('RebindPinDialog: no pin to rebind')
      return instancesApi.rebindPins(instanceId, {
        reason,
        entries: [{ kind: pin.kind, ref: pin.ref, version: targetVersion }],
      })
    },
  })

  useEffect(() => {
    if (!open) {
      setTargetVersion('')
      setReason('')
      mutation.reset()
      return
    }

    const keyHandler = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
        return
      }

      if (event.key !== 'Tab' || !dialogRef.current) return

      const focusables = dialogRef.current.querySelectorAll<HTMLElement>(
        'button, textarea, input, [href], select, [tabindex]:not([tabindex="-1"])',
      )
      if (focusables.length === 0) return

      const first = focusables[0]
      const last = focusables[focusables.length - 1]
      const current = document.activeElement

      if (event.shiftKey && current === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && current === last) {
        event.preventDefault()
        first.focus()
      }
    }

    document.addEventListener('keydown', keyHandler)
    firstFocusableRef.current?.focus()

    return () => {
      document.removeEventListener('keydown', keyHandler)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open])

  if (!open || !pin) return null

  const canSubmit = targetVersion.trim().length > 0 && reason.trim().length > 0

  const onConfirmClick = () => {
    if (!canSubmit) return
    mutation.mutate(undefined, {
      onSuccess: (result) => {
        onSuccess(result)
        onClose()
      },
    })
  }

  const errorMessage = mutation.isError
    ? ((mutation.error as unknown as ApiError | undefined)?.message ?? 'Failed to rebind pin.')
    : null

  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        background: 'var(--surface-overlay)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 1000,
      }}
      onClick={() => { if (!mutation.isPending) onClose() }}
    >
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="rebind-pin-title"
        data-testid="rebind-pin-dialog"
        onClick={(event) => event.stopPropagation()}
        style={{
          width: '480px',
          maxWidth: '92vw',
          background: 'var(--surface-card)',
          borderRadius: '8px',
          boxShadow: 'var(--shadow-dialog)',
          padding: '1rem 1.2rem',
        }}
      >
        <h3 id="rebind-pin-title" style={{ marginTop: 0, marginBottom: '.5rem' }}>
          Rebind {pin.ref}
        </h3>

        <div style={{ color: 'var(--text-secondary)', fontSize: '.85rem', marginBottom: '.75rem' }}>
          Current version: <code>{pin.version}</code>
        </div>

        <label htmlFor="rebind-target-version" style={{ display: 'block', fontSize: '.85rem', color: 'var(--color-neutral-700)', marginBottom: '.25rem' }}>
          Target version
        </label>
        <input
          id="rebind-target-version"
          data-testid="rebind-target-version"
          value={targetVersion}
          onChange={(event) => setTargetVersion(event.target.value)}
          disabled={mutation.isPending}
          style={{
            width: '100%',
            marginBottom: '.8rem',
            padding: '.5rem .6rem',
            border: '1px solid var(--color-neutral-400)',
            borderRadius: '4px',
            boxSizing: 'border-box',
          }}
        />

        <label htmlFor="rebind-reason" style={{ display: 'block', fontSize: '.85rem', color: 'var(--color-neutral-700)', marginBottom: '.25rem' }}>
          Reason (required)
        </label>
        <textarea
          id="rebind-reason"
          data-testid="rebind-reason"
          value={reason}
          onChange={(event) => setReason(event.target.value.slice(0, REASON_MAX_LENGTH))}
          rows={4}
          maxLength={REASON_MAX_LENGTH}
          disabled={mutation.isPending}
          style={{
            width: '100%',
            marginBottom: '.8rem',
            padding: '.5rem .6rem',
            border: '1px solid var(--color-neutral-400)',
            borderRadius: '4px',
            fontFamily: 'inherit',
            boxSizing: 'border-box',
          }}
        />

        {errorMessage && (
          <div
            role="alert"
            style={{
              padding: '.6rem',
              background: 'var(--color-error-tint)',
              border: '1px solid var(--color-error-border)',
              borderRadius: '4px',
              color: 'var(--color-error-dark)',
              marginBottom: '.8rem',
              fontSize: '.85rem',
            }}
          >
            {errorMessage}
          </div>
        )}

        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem' }}>
          <button
            ref={firstFocusableRef}
            onClick={onClose}
            disabled={mutation.isPending}
            style={{
              padding: '.4rem .8rem',
              border: '1px solid var(--color-neutral-400)',
              borderRadius: '4px',
              background: 'var(--surface-card)',
              cursor: mutation.isPending ? 'not-allowed' : 'pointer',
            }}
          >
            Close
          </button>
          <button
            data-testid="rebind-confirm"
            onClick={onConfirmClick}
            disabled={mutation.isPending || !canSubmit}
            style={{
              padding: '.4rem .8rem',
              border: 'none',
              borderRadius: '4px',
              background: 'var(--interactive-primary)',
              color: 'var(--text-inverse)',
              cursor: mutation.isPending || !canSubmit ? 'not-allowed' : 'pointer',
            }}
          >
            {mutation.isPending ? 'Rebinding…' : 'Confirm rebind'}
          </button>
        </div>
      </div>
    </div>
  )
}
