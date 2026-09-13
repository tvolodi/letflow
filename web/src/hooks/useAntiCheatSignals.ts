/** useAntiCheatSignals — REQ-338
 *
 *  Wires the three browser signals REQ-333's `Letflow.Exam.AntiCheat.record_signal/4`
 *  accepts (`visibilitychange` -> tab_switch, `blur` -> blur,
 *  `fullscreenchange` -> fullscreen_exit) to `examApi.reportEvent`, only while
 *  `enabled` is true. Listeners are attached and torn down by this same
 *  effect: when `enabled` flips to false (leaving the in-progress screen,
 *  e.g. after a `submit`-branch auto-submit) or the component unmounts, the
 *  cleanup function removes every listener, so no further browser event can
 *  trigger a `reportEvent` call after that point — the requirement's own
 *  teardown acceptance criterion.
 */

import { useEffect } from 'react'
import { examApi } from '@/api/exam'
import type { AntiCheatSignalOutcome, AntiCheatSignalType } from '@/types/exam'

export function useAntiCheatSignals(
  sessionId: string | null,
  enabled: boolean,
  onOutcome: (outcome: AntiCheatSignalOutcome, type: AntiCheatSignalType) => void,
): void {
  useEffect(() => {
    if (!sessionId || !enabled) return undefined

    function report(type: AntiCheatSignalType) {
      void examApi
        .reportEvent(sessionId as string, type)
        .then((outcome) => onOutcome(outcome, type))
        .catch(() => {
          // Anti-cheat reporting failures are non-fatal to the candidate's
          // own exam-taking flow -- there is no retry/queue mechanism here,
          // matching REQ-333's own "no other mitigation is built" scope note.
        })
    }

    function handleVisibilityChange() {
      if (document.visibilityState === 'hidden') report('tab_switch')
    }
    function handleBlur() {
      report('blur')
    }
    function handleFullscreenChange() {
      if (!document.fullscreenElement) report('fullscreen_exit')
    }

    document.addEventListener('visibilitychange', handleVisibilityChange)
    window.addEventListener('blur', handleBlur)
    document.addEventListener('fullscreenchange', handleFullscreenChange)

    return () => {
      document.removeEventListener('visibilitychange', handleVisibilityChange)
      window.removeEventListener('blur', handleBlur)
      document.removeEventListener('fullscreenchange', handleFullscreenChange)
    }
  }, [sessionId, enabled, onOutcome])
}
