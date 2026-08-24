import { Handle, Position, type NodeProps, type Node } from '@xyflow/react'
import type { CanvasNodeData } from '@/utils/canvas/graphToFlow'

export default function TimerNode({ selected }: NodeProps<Node<CanvasNodeData>>) {
  return (
    <div
      className="timer-node"
      style={{
        width: 56,
        height: 56,
        borderRadius: '50%',
        border: '2px solid var(--color-warning)',
        background: 'var(--color-neutral-0)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        position: 'relative',
        boxShadow: selected ? 'var(--shadow-focus-brand)' : undefined,
        cursor: 'pointer',
      }}
    >
      {/* Clock icon */}
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="var(--color-warning)" strokeWidth="2">
        <circle cx="12" cy="12" r="10" />
        <polyline points="12,6 12,12 16,14" />
      </svg>

      <Handle type="target" position={Position.Top} />
      <Handle type="source" position={Position.Bottom} />
    </div>
  )
}
