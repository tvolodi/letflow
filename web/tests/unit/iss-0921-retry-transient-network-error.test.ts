// @vitest-environment node
/**
 * ISS-0921 (Q-912): retryTransientNetworkError retries connection-level
 * failures (ECONNRESET etc.) and nothing else.
 */
import { describe, it, expect, vi } from 'vitest'
import { retryTransientNetworkError } from '../e2e/helpers'

describe('retryTransientNetworkError', () => {
  it('retries ECONNRESET and returns the eventual success', async () => {
    const fn = vi.fn()
      .mockRejectedValueOnce(new Error('read ECONNRESET'))
      .mockResolvedValueOnce('ok')
    await expect(retryTransientNetworkError(fn, 3, 1)).resolves.toBe('ok')
    expect(fn).toHaveBeenCalledTimes(2)
  })

  it('gives up after the retry budget and rethrows', async () => {
    const fn = vi.fn().mockRejectedValue(new Error('connect ECONNRESET'))
    await expect(retryTransientNetworkError(fn, 2, 1)).rejects.toThrow('ECONNRESET')
    expect(fn).toHaveBeenCalledTimes(3)
  })

  it('does not retry non-network errors', async () => {
    const fn = vi.fn().mockRejectedValue(new Error('boom'))
    await expect(retryTransientNetworkError(fn, 3, 1)).rejects.toThrow('boom')
    expect(fn).toHaveBeenCalledTimes(1)
  })
})
