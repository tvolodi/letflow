import { useMemo, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { groupsApi, usersApi } from '@/api/identity'
import { queryKeys } from '@/api/queryKeys'
import type { Group, User } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'

type GroupRow = Group & {
  group_id?: string
  member_count?: number
  display_name?: string
  description?: string
  is_system?: boolean
}

function groupId(group: GroupRow): string {
  return group.group_id ?? group.id ?? ''
}

function groupTitle(group: GroupRow): string {
  return group.display_name?.trim() || group.name || groupId(group) || 'Unnamed group'
}

function groupMembers(group: GroupRow): number {
  return group.member_count ?? 0
}

function formatUser(user: User): string {
  return `${user.display_name} <${user.email}>`
}

export default function GroupsPage() {
  const qc = useQueryClient()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState({ name: '', display_name: '', description: '' })
  const [activeGroup, setActiveGroup] = useState<GroupRow | null>(null)
  const [pendingDelete, setPendingDelete] = useState<GroupRow | null>(null)
  const [selectedUserId, setSelectedUserId] = useState('')

  const { data, isLoading, isError, error, refetch } = useQuery({
    queryKey: queryKeys.admin.groups(),
    queryFn: () => groupsApi.list(),
  })

  const groups = useMemo(() => (data?.items ?? []) as GroupRow[], [data?.items])
  const activeGroupId = groupId(activeGroup ?? ({} as GroupRow))
  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  const { data: members } = useQuery({
    queryKey: queryKeys.admin.groupMembers(activeGroupId),
    queryFn: () => groupsApi.members(activeGroupId),
    enabled: Boolean(activeGroup),
  })

  const { data: users } = useQuery({
    queryKey: queryKeys.admin.users({ page_size: 200 }),
    queryFn: () => usersApi.list({ page_size: 200 }),
    enabled: Boolean(activeGroup),
  })

  const createGroup = useMutation({
    mutationFn: (body: typeof form) => groupsApi.create(body),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: queryKeys.admin.groups() })
      setCreating(false)
      setForm({ name: '', display_name: '', description: '' })
    },
  })

  const addMember = useMutation({
    mutationFn: ({ groupId: id, userId }: { groupId: string; userId: string }) => groupsApi.addMembers(id, [userId]),
    onSuccess: () => {
      if (activeGroup) {
        qc.invalidateQueries({ queryKey: queryKeys.admin.groups() })
        qc.invalidateQueries({ queryKey: queryKeys.admin.groupMembers(groupId(activeGroup)) })
      }
      setSelectedUserId('')
    },
  })

  const removeMember = useMutation({
    mutationFn: ({ groupId: id, userId }: { groupId: string; userId: string }) => groupsApi.removeMembers(id, [userId]),
    onSuccess: () => {
      if (activeGroup) {
        qc.invalidateQueries({ queryKey: queryKeys.admin.groups() })
        qc.invalidateQueries({ queryKey: queryKeys.admin.groupMembers(groupId(activeGroup)) })
      }
    },
  })

  const deleteGroup = useMutation({
    mutationFn: (id: string) => groupsApi.delete(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: queryKeys.admin.groups() }),
  })

  const availableUsers = useMemo(() => {
    const list = users?.items ?? []
    const memberIds = new Set((members ?? []).map((user) => user.id ?? user.user_id ?? ''))
    return list.filter((user) => {
      const id = user.id ?? user.user_id ?? ''
      return id !== '' && !memberIds.has(id)
    })
  }, [members, users?.items])

  const columns: DataTableColumn<GroupRow>[] = [
    { id: 'name', header: 'Name', accessor: (g) => <span style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--text-sm)' }}>{g.name}</span> },
    { id: 'display_name', header: 'Display name', accessor: groupTitle },
    { id: 'members', header: 'Members', accessor: (g) => groupMembers(g) },
    {
      id: 'description',
      header: 'Description',
      accessor: (g) => <span style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>{g.description ?? '—'}</span>,
    },
    {
      id: 'actions',
      header: 'Actions',
      accessor: (g) => {
        const memberCount = groupMembers(g)
        return (
          <div style={{ display: 'flex', gap: '.5rem', flexWrap: 'wrap' }}>
            <Button variant="primary" size="sm" onClick={() => setActiveGroup(g)}>
              Manage members
            </Button>
            {!g.is_system && memberCount === 0 && (
              <Button variant="danger" size="sm" onClick={() => setPendingDelete(g)}>
                Delete
              </Button>
            )}
          </div>
        )
      },
    },
  ]

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Groups</h2>
        <span style={{ marginLeft: 'auto' }}>
          <Button variant="primary" size="sm" onClick={() => setCreating(true)}>
            + New Group
          </Button>
        </span>
      </div>

      {creating && (
        <div style={{ background: 'var(--surface-page)', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Create group</h3>
          {(['name', 'display_name', 'description'] as const).map((f) => (
            <div key={f} style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>{f.replace('_', ' ')}</label>
              <input
                value={form[f]}
                onChange={(e) => setForm((p) => ({ ...p, [f]: e.target.value }))}
                style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', fontSize: 'var(--text-base)', boxSizing: 'border-box' }}
              />
            </div>
          ))}
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <Button variant="primary" size="sm" onClick={() => createGroup.mutate(form)}>Save</Button>
            <Button variant="secondary" size="sm" onClick={() => setCreating(false)}>Cancel</Button>
          </div>
        </div>
      )}

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          rendererState === 'rate-limit' ? getRetryAfterSeconds(error) : undefined
        }
        columns={[{ widthPercent: 25 }, { widthPercent: 30 }, { widthPercent: 10 }, { widthPercent: 25 }, { widthPercent: 10 }]}
      >
      <DataTable
        columns={columns}
        data={groups}
        emptyMessage="No groups found."
      />

      {activeGroup && (
        <div role="dialog" aria-modal="true" aria-label="Manage group members" style={{ position: 'fixed', inset: 0, background: 'var(--surface-overlay-slate)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem', zIndex: 30 }}>
          <div style={{ background: 'var(--surface-card)', width: 'min(720px, 100%)', borderRadius: '12px', padding: '1.25rem', maxHeight: '85vh', overflow: 'auto' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: '1rem', alignItems: 'start', marginBottom: '1rem' }}>
              <div>
                <h3 style={{ margin: 0 }}>Manage members</h3>
                <p style={{ margin: '.25rem 0 0', color: 'var(--text-secondary)' }}>{groupTitle(activeGroup)}</p>
              </div>
              <Button variant="ghost" size="sm" onClick={() => { setActiveGroup(null); setSelectedUserId('') }}>Close</Button>
            </div>

            <div style={{ display: 'flex', gap: '.5rem', marginBottom: '1rem', alignItems: 'end', flexWrap: 'wrap' }}>
              <label style={{ display: 'grid', gap: '.25rem', minWidth: '18rem', flex: '1 1 18rem' }}>
                <span style={{ fontSize: '.875rem', fontWeight: 600 }}>Add member</span>
                <select value={selectedUserId} onChange={(event) => setSelectedUserId(event.target.value)} style={{ padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)' }}>
                  <option value="">Select a user</option>
                  {availableUsers.map((user) => {
                    const id = user.id ?? user.user_id ?? ''
                    return <option key={id} value={id}>{formatUser(user)}</option>
                  })}
                </select>
              </label>
              <Button
                variant="primary"
                size="md"
                loading={addMember.isPending}
                disabled={!selectedUserId}
                onClick={() => {
                  if (!selectedUserId) return
                  addMember.mutate({ groupId: groupId(activeGroup), userId: selectedUserId })
                }}
              >
                Add member
              </Button>
            </div>

            <div>
              <h4 style={{ margin: '0 0 .75rem' }}>Current members</h4>
              {(members ?? []).length === 0 ? (
                <p style={{ margin: 0, color: 'var(--text-secondary)' }}>No members in this group.</p>
              ) : (
                <div style={{ display: 'grid', gap: '.5rem' }}>
                  {(members ?? []).map((user) => {
                    const id = user.id ?? user.user_id ?? ''
                    return (
                      <div key={id} style={{ display: 'flex', justifyContent: 'space-between', gap: '1rem', alignItems: 'center', border: '1px solid var(--border-default)', borderRadius: '8px', padding: '.7rem .85rem' }}>
                        <div>
                          <div style={{ fontWeight: 600 }}>{user.display_name}</div>
                          <div style={{ color: 'var(--text-secondary)', fontSize: '.875rem' }}>{user.email}</div>
                        </div>
                        <Button variant="danger" size="sm" onClick={() => removeMember.mutate({ groupId: groupId(activeGroup), userId: id })}>
                          Remove
                        </Button>
                      </div>
                    )
                  })}
                </div>
              )}
            </div>
          </div>
        </div>
      )}

      </QueryStateBoundary>

      {pendingDelete && (
        <div role="dialog" aria-modal="true" aria-label="Delete group" style={{ position: 'fixed', inset: 0, background: 'var(--surface-overlay-slate)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem', zIndex: 40 }}>
          <div style={{ background: 'var(--surface-card)', width: 'min(520px, 100%)', borderRadius: '12px', padding: '1.25rem' }}>
            <h3 style={{ marginTop: 0 }}>Delete group?</h3>
            <p style={{ color: 'var(--text-secondary)' }}>Delete {groupTitle(pendingDelete)} only if it is empty. This action cannot be undone.</p>
            <div style={{ display: 'flex', gap: '.5rem', justifyContent: 'flex-end' }}>
              <Button variant="secondary" size="md" onClick={() => setPendingDelete(null)}>Cancel</Button>
              <Button
                variant="danger"
                size="md"
                onClick={() => {
                  deleteGroup.mutate(groupId(pendingDelete))
                  setPendingDelete(null)
                }}
              >
                Delete group
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
