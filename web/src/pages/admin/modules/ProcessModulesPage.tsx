/** Process Module Catalog Page — PLC-01, PLC-02, PLC-03, PLC-04
 *
 * PLC-01: Lists all catalog entries with module_id, version, status, exportable
 * PLC-02: Publish button → 422 if interface not declared
 * PLC-03: Compatibility warning display on publish
 * PLC-04: Grant / Revoke visibility dialogs for cross-tenant distribution
 */
import { useState } from 'react'
import { useModules, useModuleShares, usePublishModule, useGrantModuleShare, useRevokeModuleShare } from '@/hooks/useModules'
import type { ProcessModuleCatalogEntry, CompatibilityWarning, ModuleShare } from '@/api/modules'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { classifyError, type RendererState } from '@/utils/classifyError'

// NOTE: entry.status values (DRAFT/ACTIVE/DEPRECATED) are exactly
// StatusBadge's "definition" domain table (design-system.md §5.1), so the
// old hand-rolled STATUS_COLORS pill is replaced by StatusBadge directly
// -- a genuine fit, not a workaround.

// ── Compatibility Warning Banner ────────────────────────────────────────────────

function CompatibilityWarningBanner({ warning }: { warning: CompatibilityWarning }) {
  return (
    <div style={{
      marginTop: '1rem',
      padding: '.75rem 1rem',
      background: 'var(--color-warning-light)',
      border: '1px solid var(--color-warning)',
      borderRadius: '6px',
    }}>
      <strong style={{ color: 'var(--color-warning-text)' }}>Compatibility Warning</strong>
      <ul style={{ margin: '.5rem 0 0 1.25rem', padding: 0, color: 'var(--color-warning-text)' }}>
        {warning.breaking_changes.map((c, i) => (
          <li key={i}>{c}</li>
        ))}
      </ul>
    </div>
  )
}

// ── Module Detail Drawer ──────────────────────────────────────────────────────

interface DetailDrawerProps {
  entry: ProcessModuleCatalogEntry | null
  onClose: () => void
  onGrant: (moduleId: string, grantingTenantId: string) => void
  onRevoke: (grant: ModuleShare) => void
}

function DetailDrawer({ entry, onClose, onGrant, onRevoke }: DetailDrawerProps) {
  const [showShares, setShowShares] = useState(false)
  const { data: sharesData } = useModuleShares(entry?.module_id ?? '')
  const shares: ModuleShare[] = sharesData?.items ?? []

  if (!entry) return null

  const shareColumns: DataTableColumn<ModuleShare>[] = [
    {
      id: 'receiving_tenant',
      header: 'Receiving Tenant',
      accessor: (s) => <span style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--text-xs)' }}>{s.receiving_tenant_id}</span>,
    },
    { id: 'granted_at', header: 'Granted At', accessor: (s) => new Date(s.granted_at).toLocaleDateString() },
    {
      id: 'actions',
      header: '',
      accessor: (s) => (
        <Button variant="danger" size="sm" onClick={() => onRevoke(s)}>
          Revoke
        </Button>
      ),
    },
  ]

  return (
    <div style={{
      position: 'fixed', inset: 0, zIndex: 50,
      display: 'flex', justifyContent: 'flex-end',
    }}>
      <div style={{
        position: 'absolute', inset: 0, background: 'var(--surface-overlay)',
      }} onClick={onClose} />
      <div style={{
        position: 'relative', width: '520px', background: 'var(--surface-card)',
        padding: '1.5rem', overflowY: 'auto',
        boxShadow: 'var(--shadow-panel)',
      }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <h3 style={{ marginTop: 0 }}>Module: {entry.module_id}</h3>
          <Button variant="ghost" size="sm" data-testid="module-detail-close" onClick={onClose}>×</Button>
        </div>
        <dl style={{ display: 'grid', gridTemplateColumns: 'auto 1fr', gap: '.5rem' }}>
          <dt style={{ color: 'var(--text-secondary)', fontSize: '.85rem' }}>Version</dt>
          <dd style={{ margin: 0, fontFamily: 'var(--font-mono)' }}>{entry.version}</dd>
          <dt style={{ color: 'var(--text-secondary)', fontSize: '.85rem' }}>Status</dt>
          <dd><StatusBadge status={entry.status} domain="definition" size="sm" /></dd>
          <dt style={{ color: 'var(--text-secondary)', fontSize: '.85rem' }}>Owning Definition ID</dt>
          <dd style={{ margin: 0, fontFamily: 'var(--font-mono)', fontSize: '.8rem', wordBreak: 'break-all' }}>{entry.owning_definition_id}</dd>
          <dt style={{ color: 'var(--text-secondary)', fontSize: '.85rem' }}>Owning Tenant ID</dt>
          <dd style={{ margin: 0, fontFamily: 'var(--font-mono)', fontSize: '.75rem', wordBreak: 'break-all' }}>{entry.owning_tenant_id}</dd>
          <dt style={{ color: 'var(--text-secondary)', fontSize: '.85rem' }}>Exportable</dt>
          <dd style={{ margin: 0 }}>{entry.exportable ? 'Yes' : 'No'}</dd>
          <dt style={{ color: 'var(--text-secondary)', fontSize: '.85rem', marginTop: '.5rem' }}>Interface Schema</dt>
          <dd style={{ margin: 0 }}>
            <pre style={{
              background: 'var(--surface-page)', padding: '.5rem',
              borderRadius: 'var(--radius-sm)', fontSize: '.75rem',
              overflowX: 'auto', maxHeight: '200px',
            }}>
              {JSON.stringify(entry.interface_schema, null, 2)}
            </pre>
          </dd>
          <dt style={{ color: 'var(--text-secondary)', fontSize: '.85rem' }}>Created</dt>
          <dd style={{ margin: 0 }}>{new Date(entry.created_at).toLocaleString()}</dd>
          <dt style={{ color: 'var(--text-secondary)', fontSize: '.85rem' }}>Updated</dt>
          <dd style={{ margin: 0 }}>{new Date(entry.updated_at).toLocaleString()}</dd>
        </dl>

        {/* PLC-04: Cross-tenant visibility management */}
        <div style={{ display: 'flex', gap: '.5rem', marginTop: '1.25rem', marginBottom: '.5rem' }}>
          <Button variant="secondary" size="sm" onClick={() => onGrant(entry.module_id, entry.owning_tenant_id)}>
            Grant Visibility
          </Button>
          <Button variant="secondary" size="sm" onClick={() => setShowShares(!showShares)}>
            View Shares ({shares.length})
          </Button>
        </div>

        {showShares && shares.length > 0 && (
          <div style={{ marginTop: '1rem' }}>
            <h4 style={{ marginBottom: '.75rem' }}>Shared With</h4>
            <DataTable
              columns={shareColumns}
              data={shares}
              emptyMessage="No shares."
            />
          </div>
        )}
      </div>
    </div>
  )
}

// ── Grant Visibility Dialog ────────────────────────────────────────────────────

interface GrantDialogProps {
  moduleId: string
  open: boolean
  onClose: () => void
  onConfirm: (receivingTenantId: string) => Promise<void>
}

function GrantVisibilityDialog({ moduleId, open, onClose, onConfirm }: GrantDialogProps) {
  const [receivingTenantId, setReceivingTenantId] = useState('')
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!open) return null

  const handleGrant = async () => {
    if (!receivingTenantId.trim()) return
    setIsLoading(true)
    setError(null)
    try {
      await onConfirm(receivingTenantId.trim())
      onClose()
      setReceivingTenantId('')
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Grant failed')
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div style={{ position: 'fixed', inset: 0, zIndex: 60, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ position: 'absolute', inset: 0, background: 'var(--surface-overlay)' }} onClick={onClose} />
      <div style={{
        position: 'relative', background: 'var(--surface-card)', borderRadius: '8px',
        padding: '1.5rem', width: '400px', boxShadow: 'var(--shadow-modal-lg)',
      }}>
        <h3 style={{ marginTop: 0 }}>Grant Module Visibility</h3>
        <p style={{ fontSize: '.9rem', color: 'var(--text-secondary)', marginBottom: '1rem' }}>
          Allow another tenant to resolve module <strong>{moduleId}</strong>.
        </p>
        <input
          value={receivingTenantId}
          onChange={e => setReceivingTenantId(e.target.value)}
          placeholder="Receiving Tenant ID (UUID)"
          style={{ width: '100%', padding: '.5rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', boxSizing: 'border-box' }}
        />
        {error && <p style={{ color: 'var(--color-error)', fontSize: '.85rem', marginTop: '.5rem' }}>{error}</p>}
        <div style={{ display: 'flex', gap: '.75rem', justifyContent: 'flex-end', marginTop: '1rem' }}>
          <Button variant="secondary" size="md" onClick={onClose}>
            Cancel
          </Button>
          <Button
            variant="primary"
            size="md"
            loading={isLoading}
            disabled={!receivingTenantId.trim()}
            onClick={handleGrant}
          >
            {isLoading ? 'Granting…' : 'Grant'}
          </Button>
        </div>
      </div>
    </div>
  )
}

// ── Revoke Confirmation Dialog ─────────────────────────────────────────────────

interface RevokeDialogProps {
  grant: ModuleShare | null
  onClose: () => void
  onConfirm: () => void
}

function RevokeVisibilityDialog({ grant, onClose, onConfirm }: RevokeDialogProps) {
  const [isLoading, setIsLoading] = useState(false)
  const revoke = useRevokeModuleShare()

  if (!grant) return null

  const handleRevoke = async () => {
    setIsLoading(true)
    try {
      await revoke.mutateAsync({ grantId: grant.grant_id, moduleId: grant.module_id })
      onConfirm()
      onClose()
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div style={{ position: 'fixed', inset: 0, zIndex: 60, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ position: 'absolute', inset: 0, background: 'var(--surface-overlay)' }} onClick={onClose} />
      <div style={{
        position: 'relative', background: 'var(--surface-card)', borderRadius: '8px',
        padding: '1.5rem', width: '400px', boxShadow: 'var(--shadow-modal-lg)',
      }}>
        <h3 style={{ marginTop: 0, color: 'var(--color-error)' }}>Revoke Module Visibility</h3>
        <p style={{ fontSize: '.9rem', color: 'var(--text-primary)' }}>
          Revoke access for tenant <strong>{grant.receiving_tenant_id}</strong> from module <strong>{grant.module_id}</strong>?
          This does not affect running instances.
        </p>
        <div style={{ display: 'flex', gap: '.75rem', justifyContent: 'flex-end', marginTop: '1rem' }}>
          <Button variant="secondary" size="md" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="danger" size="md" loading={isLoading} onClick={handleRevoke}>
            {isLoading ? 'Revoking…' : 'Revoke'}
          </Button>
        </div>
      </div>
    </div>
  )
}

// ── Main Page ──────────────────────────────────────────────────────────────────

export default function ProcessModulesPage() {
  const [selectedEntry, setSelectedEntry] = useState<ProcessModuleCatalogEntry | null>(null)
  const [grantDialogOpen, setGrantDialogOpen] = useState(false)
  const [grantModuleId, setGrantModuleId] = useState('')
  const [grantTenantId, setGrantTenantId] = useState('')
  const [revokeGrant, setRevokeGrant] = useState<ModuleShare | null>(null)
  const [publishError, setPublishError] = useState<string | null>(null)
  const [publishWarning, setPublishWarning] = useState<CompatibilityWarning | null>(null)

  const { data, isLoading, isError, error, refetch } = useModules()
  const publish = usePublishModule()
  const grant = useGrantModuleShare()
  const revoke = useRevokeModuleShare()

  const entries: ProcessModuleCatalogEntry[] = data?.items ?? []
  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  const handlePublish = async (entry: ProcessModuleCatalogEntry) => {
    setPublishError(null)
    setPublishWarning(null)
    try {
      const result = await publish.mutateAsync({ moduleId: entry.module_id, version: entry.version })
      setPublishWarning(result.compatibility_warning)
      setSelectedEntry(result.entry)
      await refetch()
    } catch (e: unknown) {
      const err = e as { response?: { data?: { code?: string; message?: string }; status?: number } }
      if (err.response?.status === 422) {
        setPublishError('Interface not declared: publish requires a declared SPC-01 interface (422 Unprocessable Entity).')
      } else if (err.response?.status === 409) {
        setPublishError('Module is already ACTIVE (409 Conflict).')
      } else {
        setPublishError(err.response?.data?.message ?? 'Publish failed')
      }
    }
  }

  const handleGrantOpen = (moduleId: string, grantingTenantId: string) => {
    setGrantModuleId(moduleId)
    setGrantTenantId(grantingTenantId)
    setGrantDialogOpen(true)
  }

  const handleGrantConfirm = async (receivingTenantId: string) => {
    await grant.mutateAsync({
      granting_tenant_id: grantTenantId,
      module_id: grantModuleId,
      receiving_tenant_id: receivingTenantId,
    })
  }

  const handleRevokeConfirm = async () => {
    if (!revokeGrant) return
    try {
      await revoke.mutateAsync({ grantId: revokeGrant.grant_id, moduleId: revokeGrant.module_id })
    } finally {
      setRevokeGrant(null)
    }
  }

  const moduleColumns: DataTableColumn<ProcessModuleCatalogEntry>[] = [
    { id: 'module_id', header: 'Module ID', accessor: (entry) => <span style={{ fontFamily: 'var(--font-mono)', fontWeight: 500 }}>{entry.module_id}</span> },
    { id: 'version', header: 'Version', accessor: (entry) => <span style={{ fontFamily: 'var(--font-mono)', color: 'var(--text-primary)' }}>{entry.version}</span> },
    { id: 'status', header: 'Status', accessor: (entry) => <StatusBadge status={entry.status} domain="definition" size="sm" /> },
    {
      id: 'exportable',
      header: 'Exportable',
      accessor: (entry) => (
        <span style={{ color: entry.exportable ? 'var(--color-success-dark)' : 'var(--text-disabled)' }}>
          {entry.exportable ? 'Yes' : 'No'}
        </span>
      ),
    },
    {
      id: 'actions',
      header: 'Actions',
      accessor: (entry) => (
        <div style={{ display: 'flex', gap: '.5rem', alignItems: 'center' }}>
          <Button variant="secondary" size="sm" onClick={() => setSelectedEntry(entry)}>
            Details
          </Button>
          {entry.status === 'DRAFT' && (
            <Button
              variant="primary"
              size="sm"
              loading={publish.isPending}
              onClick={() => handlePublish(entry)}
            >
              {publish.isPending ? 'Publishing…' : 'Publish'}
            </Button>
          )}
        </div>
      ),
    },
  ]

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '1.5rem' }}>
        <h2 style={{ margin: 0 }}>Process Module Catalog</h2>
      </div>

      {publishError && (
        <div style={{ padding: '.75rem 1rem', background: 'var(--color-error-light)', border: '1px solid var(--color-error)', borderRadius: '6px', marginBottom: '1rem', color: 'var(--color-error-dark)', fontSize: '.9rem' }}>
          <strong>Publish Failed</strong><br />
          {publishError}
        </div>
      )}

      <QueryStateBoundary
        state={rendererState}
        onRetry={refetch}
      >
        <DataTable
          columns={moduleColumns}
          data={entries}
          emptyMessage="No modules found. Register a module from a process definition."
        />
      </QueryStateBoundary>

      {publishWarning && !selectedEntry && (
        <CompatibilityWarningBanner warning={publishWarning} />
      )}

      {selectedEntry && (
        <>
          {publishWarning && selectedEntry.status === 'ACTIVE' && (
            <CompatibilityWarningBanner warning={publishWarning} />
          )}
          <DetailDrawer
            entry={selectedEntry}
            onClose={() => { setSelectedEntry(null); setPublishWarning(null); setPublishError(null) }}
            onGrant={handleGrantOpen}
            onRevoke={(grant) => setRevokeGrant(grant)}
          />
        </>
      )}

      <GrantVisibilityDialog
        open={grantDialogOpen}
        moduleId={grantModuleId}
        onClose={() => setGrantDialogOpen(false)}
        onConfirm={handleGrantConfirm}
      />

      <RevokeVisibilityDialog
        grant={revokeGrant}
        onClose={() => setRevokeGrant(null)}
        onConfirm={handleRevokeConfirm}
      />
    </div>
  )
}
