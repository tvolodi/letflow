/** InstancePinsPanel — dependency-version/provenance list for a case (REQ-399)
 *
 *  Mounted inside InstanceDetailPage.tsx alongside AttachmentPanel — same
 *  "one focused panel component per concern, own query, own
 *  QueryStateBoundary" pattern that page already follows. See
 *  lib/letflow/design/req399-instance-pin-provenance.md §4.
 */
import { useInstancePins } from '@/hooks/useInstancePins'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import type { EffectivePin, EffectivePinSource, EffectivePinKind } from '@/types/api'

interface InstancePinsPanelProps {
  instanceId: string
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

export function InstancePinsPanel({ instanceId }: InstancePinsPanelProps) {
  const pinsQuery = useInstancePins(instanceId)

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
    </section>
  )
}
