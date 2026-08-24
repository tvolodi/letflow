/** HistoryScrubber — Interactive timeline slider for event navigation */
import { useRef, useState, useCallback } from 'react'

export interface HistoryScrubberProps {
  instanceId?: string
  totalEvents: number
  currentPosition: number
  onPositionChange: (seqNum: number) => void
  isLoading?: boolean
  onResumeLive?: () => void
  isLiveMode?: boolean
}

export function HistoryScrubber(props: HistoryScrubberProps): JSX.Element {
  const {
    totalEvents,
    currentPosition,
    onPositionChange,
    isLoading = false,
    onResumeLive,
    isLiveMode = false,
  } = props

  const [isDragging, setIsDragging] = useState(false)
  const [hoveredPosition, setHoveredPosition] = useState<number | null>(null)
  const trackRef = useRef<HTMLDivElement>(null)

  const handleTrackClick = useCallback(
    (e: React.MouseEvent<HTMLDivElement>) => {
      if (!trackRef.current) return

      const rect = trackRef.current.getBoundingClientRect()
      const x = e.clientX - rect.left
      const percentage = Math.max(0, Math.min(100, (x / rect.width) * 100))
      const position = Math.round((percentage / 100) * Math.max(1, totalEvents - 1)) + 1

      onPositionChange(position)
    },
    [totalEvents, onPositionChange]
  )

  const handleThumbMouseDown = useCallback((e: React.MouseEvent<HTMLDivElement>) => {
    e.preventDefault()
    setIsDragging(true)

    const trackRect = trackRef.current?.getBoundingClientRect()
    if (!trackRect) return

    const handleMouseMove = (moveEvent: MouseEvent) => {
      const x = moveEvent.clientX - trackRect.left
      const percentage = Math.max(0, Math.min(100, (x / trackRect.width) * 100))
      const position = Math.round((percentage / 100) * Math.max(1, totalEvents - 1)) + 1

      // Debounce position changes while dragging
      onPositionChange(position)
    }

    const handleMouseUp = () => {
      setIsDragging(false)
      document.removeEventListener('mousemove', handleMouseMove)
      document.removeEventListener('mouseup', handleMouseUp)
    }

    document.addEventListener('mousemove', handleMouseMove)
    document.addEventListener('mouseup', handleMouseUp)
  }, [totalEvents, onPositionChange])

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLDivElement>) => {
      let newPosition = currentPosition
      let handled = false

      if (e.key === 'ArrowLeft' && !e.shiftKey) {
        newPosition = Math.max(1, currentPosition - 1)
        handled = true
      } else if (e.key === 'ArrowRight' && !e.shiftKey) {
        newPosition = Math.min(totalEvents, currentPosition + 1)
        handled = true
      } else if (e.shiftKey && e.key === 'ArrowLeft') {
        newPosition = Math.max(1, currentPosition - 10)
        handled = true
      } else if (e.shiftKey && e.key === 'ArrowRight') {
        newPosition = Math.min(totalEvents, currentPosition + 10)
        handled = true
      }

      if (handled) {
        e.preventDefault()
        if (newPosition !== currentPosition) {
          onPositionChange(newPosition)
        }
      }
    },
    [currentPosition, totalEvents, onPositionChange]
  )

  const percentage = totalEvents > 0 ? ((currentPosition - 1) / Math.max(1, totalEvents - 1)) * 100 : 0

  return (
    <div style={{ marginBottom: '1rem' }}>
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          marginBottom: '.5rem',
        }}
      >
        <label style={{ fontSize: '.85rem', fontWeight: 500, color: 'var(--color-neutral-700)' }}>
          Event {currentPosition} of {totalEvents}
        </label>

        <div style={{ display: 'flex', alignItems: 'center', gap: '.5rem' }}>
          {isLiveMode && (
            <span
              style={{
                display: 'inline-block',
                background: 'var(--color-success)',
                color: 'var(--text-inverse)',
                padding: '.25rem .5rem',
                borderRadius: '3px',
                fontSize: '.75rem',
                fontWeight: 600,
              }}
            >
              Live
            </span>
          )}

          {!isLiveMode && onResumeLive && (
            <button
              onClick={() => onResumeLive()}
              style={{
                padding: '.25rem .5rem',
                background: 'var(--interactive-primary)',
                color: 'var(--text-inverse)',
                border: 'none',
                borderRadius: '3px',
                fontSize: '.75rem',
                fontWeight: 500,
                cursor: 'pointer',
              }}
            >
              Resume live
            </button>
          )}

          {isLoading && (
            <span style={{ fontSize: '.75rem', color: 'var(--text-secondary)' }}>Loading…</span>
          )}
        </div>
      </div>

      {/* Scrubber track */}
      <div
        ref={trackRef}
        onMouseMove={(e) => {
          if (!trackRef.current || isDragging) return
          const rect = trackRef.current.getBoundingClientRect()
          const x = e.clientX - rect.left
          const percentage = Math.max(0, Math.min(100, (x / rect.width) * 100))
          const position = Math.round((percentage / 100) * Math.max(1, totalEvents - 1)) + 1
          setHoveredPosition(position)
        }}
        onMouseLeave={() => setHoveredPosition(null)}
        onClick={handleTrackClick}
        onKeyDown={handleKeyDown}
        tabIndex={0}
        style={{
          position: 'relative',
          width: '100%',
          height: '6px',
          background: 'var(--border-default)',
          borderRadius: '3px',
          cursor: isDragging ? 'grabbing' : 'pointer',
          outline: 'none',
          border: isDragging ? '2px solid var(--interactive-primary)' : 'none',
        }}
      >
        {/* Progress fill */}
        <div
          style={{
            position: 'absolute',
            left: 0,
            top: 0,
            height: '100%',
            width: `${percentage}%`,
            background: 'var(--interactive-primary)',
          }}
        />

        {/* Slider thumb */}
        <div
          onMouseDown={handleThumbMouseDown}
          style={{
            position: 'absolute',
            left: `calc(${percentage}% - 6px)`,
            top: '-5px',
            width: '16px',
            height: '16px',
            background: 'var(--interactive-primary)',
            border: '2px solid var(--surface-card)',
            borderRadius: '50%',
            cursor: isDragging ? 'grabbing' : 'grab',
            boxShadow: 'var(--shadow-sm)',
            transition: isDragging ? 'none' : 'left 0.1s',
          }}
        />

        {/* Hover tooltip */}
        {hoveredPosition !== null && (
          <div
            style={{
              position: 'absolute',
              left: `calc(${((hoveredPosition - 1) / Math.max(1, totalEvents - 1)) * 100}%)`,
              top: '-30px',
              transform: 'translateX(-50%)',
              background: 'var(--surface-sidebar)',
              color: 'var(--color-neutral-300)',
              padding: '.25rem .5rem',
              borderRadius: '3px',
              fontSize: '.7rem',
              whiteSpace: 'nowrap',
              pointerEvents: 'none',
            }}
          >
            Event {hoveredPosition}
          </div>
        )}
      </div>
    </div>
  )
}
