import React from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '@/auth/AuthContext'

export function PermissionDenied(): React.ReactElement {
  const { session } = useAuth()
  const isCandidate = session?.roles.includes('CANDIDATE') ?? false

  return (
    <div style={{ padding: '1.5rem' }}>
      <p style={{ marginBottom: '.75rem' }}>
        You do not have access to this area. Contact your tenant administrator.
      </p>
      {isCandidate ? <Link to="/exam">Go to Exams</Link> : <Link to="/tasks">My Tasks</Link>}
    </div>
  )
}
