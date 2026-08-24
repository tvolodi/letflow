import {
  BaseEdge,
  EdgeLabelRenderer,
  getBezierPath,
  type EdgeProps,
  type Edge,
} from '@xyflow/react'
import type { CanvasEdgeData } from '@/utils/canvas/graphToFlow'

export default function ConditionEdge({
  id,
  sourceX,
  sourceY,
  targetX,
  targetY,
  sourcePosition,
  targetPosition,
  data,
  selected,
}: EdgeProps<Edge<CanvasEdgeData>>) {
  const [edgePath, labelX, labelY] = getBezierPath({
    sourceX,
    sourceY,
    sourcePosition,
    targetX,
    targetY,
    targetPosition,
  })

  const isDefault = data?.isDefault ?? false
  const condition = data?.condition

  const strokeDasharray = isDefault ? '5,5' : undefined
  const stroke = selected ? 'var(--color-brand-500)' : 'var(--color-neutral-500)'

  const labelText = isDefault
    ? 'D'
    : condition
      ? condition.length > 30
        ? condition.slice(0, 30) + '…'
        : condition
      : null

  const labelBg = isDefault
    ? 'var(--color-info-light)'
    : 'var(--color-warning-light)'

  return (
    <>
      <BaseEdge
        id={id}
        path={edgePath}
        style={{
          stroke,
          strokeWidth: selected ? 2 : 1.5,
          strokeDasharray,
        }}
      />
      {labelText && (
        <EdgeLabelRenderer>
          <div
            style={{
              position: 'absolute',
              transform: `translate(-50%, -50%) translate(${labelX}px,${labelY}px)`,
              background: labelBg,
              padding: isDefault ? '1px 6px' : '2px 8px',
              borderRadius: 4,
              fontSize: 'var(--text-xs, 0.7rem)',
              fontWeight: isDefault ? 700 : 400,
              color: 'var(--text-primary)',
              fontFamily: isDefault ? undefined : 'var(--font-mono, monospace)',
              pointerEvents: 'none',
              whiteSpace: 'nowrap',
              maxWidth: 160,
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              border: `1px solid ${isDefault ? 'var(--color-info)' : 'var(--color-warning)'}`,
              lineHeight: 1.4,
            }}
          >
            {labelText}
          </div>
        </EdgeLabelRenderer>
      )}
    </>
  )
}
