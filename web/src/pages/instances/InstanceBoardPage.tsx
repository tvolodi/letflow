import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { useInstances, instanceKeys, useStartInstance } from '@/hooks/useInstances'
import { useDefinitions, useDefinition } from '@/hooks/useDefinitions'
import { useAuth } from '@/auth/AuthContext'
import { usePolling } from '@/hooks/usePolling'
import { queryKeys } from '@/api/queryKeys'
import type { ProcessInstance, InstanceStatus } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { Button } from '@/components/ui/Button'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { PaginationControls } from '@/components/ui/PaginationControls'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'

const STATUS_OPTIONS: InstanceStatus[] = ['ACTIVE', 'COMPLETED', 'CANCELLED', 'ERROR']
const START_ROLES = ['PLATFORM_ADMIN', 'PROCESS_OPERATOR', 'PROCESS_DESIGNER']

function toISODate(value: string | undefined): string {
  if (!value) return '—'
  return new Date(value).toLocaleString()
}

function toRefreshLabel(value: string | null): string {
  if (!value) return 'Not yet refreshed'
  return new Date(value).toLocaleTimeString()
}

function parseStatusFilter(searchParams: URLSearchParams): InstanceStatus[] {
  const raw = searchParams.get('status')
  if (!raw) return []
  return raw
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry): entry is InstanceStatus => STATUS_OPTIONS.includes(entry as InstanceStatus))
}

export default function InstanceBoardPage() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { session } = useAuth()
  const [searchParams, setSearchParams] = useSearchParams()

  const statusFilters = useMemo(() => parseStatusFilter(searchParams), [searchParams])
  const definitionName = searchParams.get('definitionName') ?? ''
  const definitionId = searchParams.get('definitionId') ?? undefined
  const pageSizeRaw = Number(searchParams.get('pageSize') ?? '25')
  const pageSize = Number.isFinite(pageSizeRaw) && pageSizeRaw > 0 ? pageSizeRaw : 25

  // Cursor-based pagination history: each entry is the cursor that produced
  // the *next* page. page N (1-indexed) corresponds to cursorStack[N - 2].
  // Mirrors the pattern already used by web/src/pages/admin/AuditLogPage.tsx
  // for the same PaginationControls cursor-pagination case.
  const [cursorStack, setCursorStack] = useState<string[]>([])
  const cursor = cursorStack[cursorStack.length - 1]

  const [showStart, setShowStart] = useState(false)
  const [startDefinitionName, setStartDefinitionName] = useState(definitionName)
  const [startDefinitionVersion, setStartDefinitionVersion] = useState('')
  const [startCorrelationKey, setStartCorrelationKey] = useState('')
  const [startVariablesJson, setStartVariablesJson] = useState('{\n  \n}')
  const [startError, setStartError] = useState<string | null>(null)
  const [startValidationError, setStartValidationError] = useState<string | null>(null)

  const canStartInstance = session?.roles.some((role) => START_ROLES.includes(role)) ?? false

  const { data: definitionTypeahead } = useDefinitions({
    status: 'ACTIVE',
    name: definitionName || undefined,
  })

  const { data: activeDefinitionByName, isLoading: isLoadingActiveDefinition } = useDefinition(
    definitionId ?? '',
  )

  const instancesQuery = useInstances({
    status: statusFilters.length > 0 ? statusFilters : undefined,
    definition_id: definitionId,
    cursor,
    page_size: pageSize,
  })
  const polling = usePolling({ queryKeyPrefix: queryKeys.instances.all })

  const startInstance = useStartInstance()

  useEffect(() => {
    if (definitionId) {
      setStartDefinitionVersion(activeDefinitionByName?.version ?? '')
      return
    }
    setStartDefinitionVersion('')
  }, [definitionId, activeDefinitionByName?.version])

  const onStatusToggle = (status: InstanceStatus) => {
    const next = new Set(statusFilters)
    if (next.has(status)) next.delete(status)
    else next.add(status)

    const updated = new URLSearchParams(searchParams)
    const values = Array.from(next)
    if (values.length === 0) updated.delete('status')
    else updated.set('status', values.join(','))
    setSearchParams(updated)
    setCursorStack([])
  }

  const onDefinitionInputChange = (value: string) => {
    const updated = new URLSearchParams(searchParams)
    if (!value.trim()) {
      updated.delete('definitionName')
      updated.delete('definitionId')
    } else {
      updated.set('definitionName', value)
      updated.delete('definitionId')
    }
    setSearchParams(updated)
    setCursorStack([])
  }

  const onResolveDefinition = () => {
    const activeList = definitionTypeahead?.items ?? []
    const exact = activeList.find((item) => item.name === definitionName)

    if (exact) {
      const updated = new URLSearchParams(searchParams)
      updated.set('definitionName', exact.name)
      updated.set('definitionId', exact.id)
      setSearchParams(updated)
      setCursorStack([])
    }
  }

  const currentPage = cursorStack.length + 1
  const nextCursor = instancesQuery.data?.next_cursor ?? null

  const onPageChange = (newPage: number) => {
    if (newPage < currentPage) {
      setCursorStack((prev) => prev.slice(0, -1))
    } else if (nextCursor) {
      setCursorStack((prev) => [...prev, nextCursor])
    }
  }

  const openStartDialog = () => {
    setStartDefinitionName(definitionName)
    setStartDefinitionVersion(activeDefinitionByName?.version ?? '')
    setStartCorrelationKey('')
    setStartVariablesJson('{\n  \n}')
    setStartError(null)
    setStartValidationError(null)
    setShowStart(true)
  }

  const closeStartDialog = () => {
    setShowStart(false)
  }

  const onStartDefinitionNameChange = (value: string) => {
    setStartDefinitionName(value)

    const activeList = definitionTypeahead?.items ?? []
    const exact = activeList.find((item) => item.name === value)
    if (exact) {
      const updated = new URLSearchParams(searchParams)
      updated.set('definitionName', exact.name)
      updated.set('definitionId', exact.id)
      setSearchParams(updated)
      setStartDefinitionVersion(exact.version)
    } else {
      setStartDefinitionVersion('')
    }
  }

  const submitStartInstance = async () => {
    setStartError(null)
    setStartValidationError(null)

    if (!definitionId) {
      setStartValidationError('Select a valid active definition name.')
      return
    }

    let parsedVariables: Record<string, unknown>
    try {
      const parsed = JSON.parse(startVariablesJson) as unknown
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        setStartValidationError('Initial variables must be a JSON object.')
        return
      }
      parsedVariables = parsed as Record<string, unknown>
    } catch {
      setStartValidationError('Initial variables must be valid JSON.')
      return
    }

    try {
      const created = await startInstance.mutateAsync({
        definition_id: definitionId,
        correlation_key: startCorrelationKey.trim() || undefined,
        initial_variables: parsedVariables,
      })
      await qc.invalidateQueries({ queryKey: instanceKeys.all })
      setShowStart(false)
      navigate(`/instances/${created.instance_id}`)
    } catch (err: unknown) {
      const e = err as { message?: string }
      setStartError(e.message ?? 'Failed to start instance.')
    }
  }

  const columns: DataTableColumn<ProcessInstance>[] = [
    {
      id: 'instance_id',
      header: 'Instance ID',
      accessor: (inst) => (
        <Link
          data-testid={`instance-link-${inst.instance_id}`}
          to={`/instances/${inst.instance_id}`}
          style={{ color: 'var(--interactive-primary)', fontFamily: 'var(--font-mono)', fontSize: 'var(--text-xs)' }}
        >
          {inst.instance_id.slice(0, 8)}...
        </Link>
      ),
    },
    {
      id: 'definition',
      header: 'Definition',
      accessor: (inst) => `${inst.definition_name} v${inst.definition_version}`,
    },
    {
      id: 'status',
      header: 'Status',
      accessor: (inst) => <StatusBadge status={inst.status} domain="instance" size="sm" />,
    },
    {
      id: 'correlation_key',
      header: 'Correlation Key',
      accessor: (inst) => inst.correlation_key ?? '—',
    },
    {
      id: 'started_at',
      header: 'Started',
      accessor: (inst) => toISODate(inst.started_at),
    },
    {
      id: 'updated_at',
      header: 'Last Updated',
      accessor: (inst) => toISODate(inst.updated_at ?? inst.started_at),
    },
  ]

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '1rem' }}>
        <h2 style={{ margin: 0 }}>Instances</h2>
        {canStartInstance && (
          <Button
            data-testid="start-instance-button"
            variant="primary"
            size="md"
            onClick={openStartDialog}
          >
            Start Instance
          </Button>
        )}
      </div>

      <div style={{ display: 'flex', justifyContent: 'flex-end', alignItems: 'center', gap: '.6rem', marginBottom: '.8rem' }}>
        <span style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>
          Last refreshed: {toRefreshLabel(polling.lastRefreshedAt)}
        </span>
        <Button
          variant="secondary"
          size="sm"
          loading={instancesQuery.isRefetching}
          disabled={instancesQuery.isRefetching}
          onClick={() => void polling.refreshNow()}
        >
          {instancesQuery.isRefetching ? 'Refreshing...' : 'Refresh'}
        </Button>
      </div>

      <div data-testid="instance-filter-bar" style={{ display: 'grid', gap: '.75rem', marginBottom: '1rem' }}>
        <div style={{ display: 'flex', gap: '.6rem', flexWrap: 'wrap' }}>
          {STATUS_OPTIONS.map((status) => (
            <label
              key={status}
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                gap: '.35rem',
                fontSize: 'var(--text-sm)',
                color: 'var(--text-primary)',
              }}
            >
              <input
                data-testid={`status-filter-${status.toLowerCase()}`}
                type="checkbox"
                checked={statusFilters.includes(status)}
                onChange={() => onStatusToggle(status)}
              />
              {status}
            </label>
          ))}
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: '.5rem', flexWrap: 'wrap' }}>
          <label htmlFor="instance-definition-filter" style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>
            Definition
          </label>
          <input
            id="instance-definition-filter"
            data-testid="instance-definition-filter"
            list="instance-definition-filter-options"
            value={definitionName}
            onChange={(e) => onDefinitionInputChange(e.target.value)}
            onBlur={onResolveDefinition}
            placeholder="Type definition name"
            style={{
              minWidth: '260px',
              padding: '.35rem .6rem',
              borderRadius: 'var(--radius-sm)',
              border: '1px solid var(--border-default)',
              fontSize: 'var(--text-sm)',
            }}
          />
          <datalist id="instance-definition-filter-options">
            {(definitionTypeahead?.items ?? []).map((def) => (
              <option key={def.id} value={def.name}>{def.name} (v{def.version})</option>
            ))}
          </datalist>
          {definitionId && (
            <span style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>
              using active version {activeDefinitionByName?.version ?? '...'}
            </span>
          )}
        </div>
      </div>

      <QueryStateBoundary
        state={(instancesQuery.isLoading ? 'loading' : instancesQuery.isError ? classifyError(instancesQuery.error) : 'success') as RendererState}
        onRetry={() => { void instancesQuery.refetch() }}
        rateLimitRetryAfter={
          instancesQuery.isError && classifyError(instancesQuery.error) === 'rate-limit'
            ? getRetryAfterSeconds(instancesQuery.error)
            : undefined
        }
        columns={[{ widthPercent: 15 }, { widthPercent: 20 }, { widthPercent: 10 }, { widthPercent: 20 }, { widthPercent: 17 }, { widthPercent: 18 }]}
      >
      {instancesQuery.data && (
        <div data-testid="instance-board-table">
          <DataTable<ProcessInstance>
            columns={columns}
            data={instancesQuery.data.items}
            emptyMessage="No instances found."
          />

          <div style={{ marginTop: '1rem' }}>
            <PaginationControls
              page={currentPage}
              pageSize={pageSize}
              totalItems={null}
              hasNextPage={Boolean(nextCursor)}
              onPageChange={onPageChange}
            />
          </div>
        </div>
      )}
      </QueryStateBoundary>

      {showStart && (
        <div
          data-testid="start-instance-dialog"
          style={{
            position: 'fixed',
            inset: 0,
            background: 'var(--surface-overlay)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            zIndex: 1000,
          }}
          onClick={closeStartDialog}
        >
          <div
            onClick={(e) => e.stopPropagation()}
            style={{
              width: '560px',
              maxWidth: '92vw',
              background: 'var(--surface-card)',
              borderRadius: 'var(--radius-sm)',
              boxShadow: 'var(--shadow-dialog)',
              padding: '1rem 1.2rem',
            }}
          >
            <h3 style={{ marginTop: 0, marginBottom: '.75rem' }}>Start Instance</h3>

            {startError && <p style={{ marginTop: 0, color: 'var(--color-error-dark)' }}>{startError}</p>}
            {startValidationError && <p style={{ marginTop: 0, color: 'var(--color-error-dark)' }}>{startValidationError}</p>}

            <label htmlFor="start-definition-name" style={{ display: 'block', fontSize: 'var(--text-sm)', color: 'var(--text-primary)', marginBottom: '.25rem' }}>
              Definition name
            </label>
            <input
              id="start-definition-name"
              data-testid="start-definition-name"
              list="instance-definition-filter-options"
              value={startDefinitionName}
              onChange={(e) => onStartDefinitionNameChange(e.target.value)}
              style={{
                width: '100%',
                marginBottom: '.6rem',
                padding: '.4rem .6rem',
                border: '1px solid var(--border-default)',
                borderRadius: 'var(--radius-sm)',
              }}
            />

            <label htmlFor="start-definition-version" style={{ display: 'block', fontSize: 'var(--text-sm)', color: 'var(--text-primary)', marginBottom: '.25rem' }}>
              Active version (auto-selected)
            </label>
            <input
              id="start-definition-version"
              data-testid="start-definition-version"
              value={startDefinitionVersion}
              readOnly
              placeholder={isLoadingActiveDefinition ? 'Loading active version…' : ''}
              style={{
                width: '100%',
                marginBottom: '.6rem',
                padding: '.4rem .6rem',
                border: '1px solid var(--border-default)',
                borderRadius: 'var(--radius-sm)',
                background: 'var(--color-neutral-50)',
              }}
            />

            <label htmlFor="start-correlation-key" style={{ display: 'block', fontSize: 'var(--text-sm)', color: 'var(--text-primary)', marginBottom: '.25rem' }}>
              Correlation key (optional)
            </label>
            <input
              id="start-correlation-key"
              data-testid="start-correlation-key"
              value={startCorrelationKey}
              onChange={(e) => setStartCorrelationKey(e.target.value)}
              style={{
                width: '100%',
                marginBottom: '.6rem',
                padding: '.4rem .6rem',
                border: '1px solid var(--border-default)',
                borderRadius: 'var(--radius-sm)',
              }}
            />

            <label htmlFor="start-variables-json" style={{ display: 'block', fontSize: 'var(--text-sm)', color: 'var(--text-primary)', marginBottom: '.25rem' }}>
              Initial variables (JSON object)
            </label>
            <textarea
              id="start-variables-json"
              data-testid="start-variables-json"
              rows={8}
              value={startVariablesJson}
              onChange={(e) => setStartVariablesJson(e.target.value)}
              style={{
                width: '100%',
                marginBottom: '.75rem',
                padding: '.5rem .6rem',
                border: '1px solid var(--border-default)',
                borderRadius: 'var(--radius-sm)',
                fontFamily: 'var(--font-mono)',
              }}
            />

            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem' }}>
              <Button variant="secondary" size="md" onClick={closeStartDialog}>
                Cancel
              </Button>
              <Button
                data-testid="submit-start-instance"
                variant="primary"
                size="md"
                loading={startInstance.isPending}
                disabled={startInstance.isPending}
                onClick={() => void submitStartInstance()}
              >
                {startInstance.isPending ? 'Starting…' : 'Start'}
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
