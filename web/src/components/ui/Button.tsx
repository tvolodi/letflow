/** Button — design-system primitive (REQ-272, docs/frontend/design-system.md §7.1)
 *
 *  variant: primary | secondary | danger | ghost
 *  size: sm | md | lg
 *  All colors/spacing/typography are sourced from web/src/styles/tokens.css
 *  custom properties — no hex/rgb/hsl literal appears in this file.
 */

import React, { useState } from 'react'

export interface ButtonProps {
  variant: 'primary' | 'secondary' | 'danger' | 'ghost'
  size: 'sm' | 'md' | 'lg'
  loading?: boolean
  disabled?: boolean
  onClick?: () => void
  children: React.ReactNode
  'data-testid'?: string
}

interface VariantStyle {
  background: string
  border: string
  color: string
  hoverBackground: string
}

const VARIANT_STYLES: Record<ButtonProps['variant'], VariantStyle> = {
  primary: {
    background: 'var(--interactive-primary)',
    border: 'none',
    color: 'var(--text-inverse)',
    hoverBackground: 'var(--interactive-primary-hover)',
  },
  secondary: {
    background: 'var(--surface-card)',
    border: '1px solid var(--interactive-primary)',
    color: 'var(--interactive-primary)',
    hoverBackground: 'var(--color-neutral-100)',
  },
  danger: {
    background: 'var(--interactive-danger)',
    border: 'none',
    color: 'var(--text-inverse)',
    hoverBackground: 'var(--interactive-danger-hover)',
  },
  ghost: {
    background: 'transparent',
    border: 'none',
    color: 'var(--text-secondary)',
    hoverBackground: 'var(--color-neutral-100)',
  },
}

interface SizeStyle {
  padding: string
  fontSize: string
}

const SIZE_STYLES: Record<ButtonProps['size'], SizeStyle> = {
  sm: { padding: 'var(--space-1) var(--space-3)', fontSize: 'var(--text-sm)' },
  md: { padding: 'var(--space-2) var(--space-4)', fontSize: 'var(--text-base)' },
  lg: { padding: 'var(--space-3) var(--space-6)', fontSize: 'var(--text-lg)' },
}

export function Button(props: ButtonProps): React.ReactElement {
  const { variant, size, loading = false, disabled = false, onClick, children } = props
  const testId = props['data-testid'] ?? 'ds-button'

  const [hovered, setHovered] = useState(false)

  const variantStyle = VARIANT_STYLES[variant]
  const sizeStyle = SIZE_STYLES[size]
  const isDisabled = disabled || loading

  return (
    <button
      type="button"
      data-testid={testId}
      onClick={onClick}
      disabled={isDisabled}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      style={{
        background: hovered && !isDisabled ? variantStyle.hoverBackground : variantStyle.background,
        border: variantStyle.border,
        color: variantStyle.color,
        padding: sizeStyle.padding,
        fontSize: sizeStyle.fontSize,
        fontWeight: 'var(--font-medium)',
        borderRadius: 'var(--radius-sm)',
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--space-2)',
        opacity: disabled && !loading ? 0.6 : 1,
        cursor: isDisabled ? 'not-allowed' : 'pointer',
      }}
    >
      {loading && (
        <span
          data-testid="ds-button-spinner"
          aria-hidden="true"
          style={{
            display: 'inline-block',
            width: '0.9em',
            height: '0.9em',
            borderRadius: '50%',
            border: '2px solid currentColor',
            borderTopColor: 'transparent',
            animation: 'ds-button-spin 0.6s linear infinite',
          }}
        />
      )}
      {children}
      <style>
        {`@keyframes ds-button-spin { to { transform: rotate(360deg); } }`}
      </style>
    </button>
  )
}
