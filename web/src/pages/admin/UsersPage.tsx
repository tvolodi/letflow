import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { usersApi, rolesApi } from '@/api/identity'
import { queryKeys } from '@/api/queryKeys'
import type { User } from '@/types/api'
import { useNavigate } from 'react-router-dom'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'

function roleList(user: User): string[] {
  return Array.isArray(user.roles) ? user.roles : []
}

function displayUsername(user: User): string {
  if (typeof user.username === 'string' && user.username.length > 0) return user.username
  if (typeof user.email === 'string' && user.email.length > 0) {
    return user.email.split('@')[0]
  }
  return 'unknown-user'
}

export default function UsersPage() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [creating, setCreating] = useState(false)
  const [searchDraft, setSearchDraft] = useState('')
  const [searchApplied, setSearchApplied] = useState('')
  const [form, setForm] = useState({ username: '', email: '', display_name: '', password: '' })
  const [createRoleIds, setCreateRoleIds] = useState<string[]>([])
  const [error, setError] = useState<string | null>(null)

  const usersQueryKey = queryKeys.admin.users({ search: searchApplied || undefined })

  const { data, isLoading, isError, error: queryError, refetch } = useQuery({
    queryKey: usersQueryKey,
    queryFn: () => usersApi.list({ search: searchApplied || undefined }),
  })

  const { data: roles } = useQuery({
    queryKey: queryKeys.admin.roles(),
    queryFn: () => rolesApi.list(),
  })

  const createUser = useMutation({
    mutationFn: () => usersApi.create({ ...form, role_ids: createRoleIds }),
    onSuccess: (createdUser) => {
      qc.invalidateQueries({ queryKey: queryKeys.admin.users() })
      setCreating(false)
      setForm({ username: '', email: '', display_name: '', password: '' })
      setCreateRoleIds([])
      navigate(`/admin/users/${createdUser.id}`)
    },
    onError: (e) => {
      setError((e as Error).message)
    },
  })

  function toggleRole(roleId: string, selectedIds: string[], setter: (next: string[]) => void): void {
    setter(selectedIds.includes(roleId) ? selectedIds.filter((id) => id !== roleId) : [...selectedIds, roleId])
  }

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Users</h2>
        <button
          onClick={() => setCreating(true)}
          data-testid="admin-users-new"
          style={{ marginLeft: 'auto', padding: '.4rem .9rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
        >
          + New User
        </button>
      </div>

      <div style={{ display: 'flex', gap: '.5rem', marginBottom: '1rem' }}>
        <input
          data-testid="admin-users-search"
          value={searchDraft}
          onChange={(e) => setSearchDraft(e.target.value)}
          placeholder="Search users"
          style={{ width: '20rem', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
        />
        <button
          onClick={() => setSearchApplied(searchDraft)}
          style={{ padding: '.4rem .9rem', background: '#2563eb', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
        >
          Apply
        </button>
      </div>

      {creating && (
        <div style={{ background: '#f8fafc', border: '1px solid #e2e8f0', borderRadius: '6px', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Create user</h3>
          {error && <p style={{ color: '#dc2626', marginBottom: '.75rem', fontSize: '.875rem' }}>{error}</p>}
          {([
            { key: 'username', label: 'Username', type: 'text' },
            { key: 'display_name', label: 'Display name', type: 'text' },
            { key: 'email', label: 'Email', type: 'email' },
            { key: 'password', label: 'Password', type: 'password' },
          ] as const).map((f) => (
            <div key={f.key} style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>{f.label}</label>
              <input
                type={f.type}
                aria-label={f.label}
                value={form[f.key]}
                onChange={(e) => setForm((p) => ({ ...p, [f.key]: e.target.value }))}
                style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid #cbd5e1', borderRadius: '4px', fontSize: '.9rem', boxSizing: 'border-box' }}
              />
            </div>
          ))}

          <div style={{ marginBottom: '.75rem' }}>
            <p style={{ margin: '0 0 .35rem', fontSize: '.875rem', fontWeight: 500 }}>Roles</p>
            {(roles?.items ?? []).map((role) => (
              <label key={role.id} style={{ display: 'flex', alignItems: 'center', gap: '.4rem', marginBottom: '.25rem' }}>
                <input
                  name="role_ids"
                  type="checkbox"
                  checked={createRoleIds.includes(role.id)}
                  onChange={() => toggleRole(role.id, createRoleIds, setCreateRoleIds)}
                />
                <span>{role.name}</span>
              </label>
            ))}
          </div>

          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button
              onClick={() => createUser.mutate()}
              disabled={createUser.isPending}
              style={{ padding: '.4rem .9rem', background: '#16a34a', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
            >
              Create user
            </button>
            <button
              onClick={() => { setCreating(false); setError(null) }}
              style={{ padding: '.4rem .9rem', background: '#6b7280', color: '#fff', border: 'none', borderRadius: '4px', cursor: 'pointer', fontSize: '.85rem' }}
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      <QueryStateBoundary
        state={isLoading ? 'loading' : isError ? classifyError(queryError) : 'success' as RendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          isError && classifyError(queryError) === 'rate-limit'
            ? getRetryAfterSeconds(queryError)
            : undefined
        }
        columns={[{ widthPercent: 20 }, { widthPercent: 25 }, { widthPercent: 25 }, { widthPercent: 15 }, { widthPercent: 10 }, { widthPercent: 5 }]}
      >
      <table data-testid="admin-users-table" style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.9rem' }}>
        <thead>
          <tr style={{ background: '#f1f5f9', textAlign: 'left' }}>
            <th style={{ padding: '.6rem .8rem' }}>Username</th>
            <th style={{ padding: '.6rem .8rem' }}>Display name</th>
            <th style={{ padding: '.6rem .8rem' }}>Email</th>
            <th style={{ padding: '.6rem .8rem' }}>Roles</th>
            <th style={{ padding: '.6rem .8rem' }}>Status</th>
            <th style={{ padding: '.6rem .8rem' }}>Created</th>
          </tr>
        </thead>
        <tbody>
          {(data?.items ?? []).map((u: User) => (
            <tr key={u.id ?? u.user_id ?? `${u.email}-${u.created_at}`} style={{ borderBottom: '1px solid #e2e8f0' }}>
              <td style={{ padding: '.6rem .8rem' }}>{displayUsername(u)}</td>
              <td style={{ padding: '.6rem .8rem' }}>{u.display_name}</td>
              <td style={{ padding: '.6rem .8rem' }}>{u.email}</td>
              <td style={{ padding: '.6rem .8rem', fontSize: '.8rem', color: '#64748b' }}>{roleList(u).join(', ')}</td>
              <td style={{ padding: '.6rem .8rem' }}>
                <span style={{ color: u.is_active ? '#16a34a' : '#9ca3af', fontWeight: 600, fontSize: '.8rem' }}>
                  {u.is_active ? 'ACTIVE' : 'INACTIVE'}
                </span>
              </td>
              <td style={{ padding: '.6rem .8rem' }}>{new Date(u.created_at).toLocaleDateString('en-US')}</td>
            </tr>
          ))}
        </tbody>
      </table>
      </QueryStateBoundary>

    </div>
  )
}
