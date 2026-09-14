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
 *
 *  FLUSH-BEFORE-REPORT (ISS-0654). A signal's outcome can carry
 *  `action_taken: 'submit'` — the server already folded the submission into
 *  its handling of THIS `reportEvent` call, so whatever the candidate last
 *  had saved is exactly what gets graded. `ExamSessionPage`'s short_text
 *  question type holds an uncommitted keystroke draft client-side
 *  (`textDraft`) that only reaches the server on the textarea's `onBlur` --
 *  an event a forced, signal-driven submit never waits for. The optional
 *  `flushBeforeReport` callback lets the caller synchronously-await any such
 *  pending save; it is invoked and its promise is awaited BEFORE
 *  `examApi.reportEvent` fires, so a flush-triggered `saveAnswer` always
 *  resolves (or rejects) strictly before the anti-cheat report reaches the
 *  server, never racing it. It is read through a ref (`flushRef`) rather
 *  than sitting in this effect's own dependency array so that its identity
 *  changing on every keystroke (it closes over the live draft) does not tear
 *  down and re-attach the listeners on every keystroke -- only `sessionId`,
 *  `enabled`, and `onOutcome` changing does that, matching the doc comment
 *  above.
 */

import { useEffect, useRef } from 'react'
import { examApi } from '@/api/exam'
import type { AntiCheatSignalOutcome, AntiCheatSignalType } from '@/types/exam'

export function useAntiCheatSignals(
  sessionId: string | null,
  enabled: boolean,
  onOutcome: (outcome: AntiCheatSignalOutcome, type: AntiCheatSignalType) => void,
  flushBeforeReport?: () => Promise<void> | void,
): void {
  const flushRef = useRef(flushBeforeReport)
  useEffect(() => {
    flushRef.current = flushBeforeReport
  }, [flushBeforeReport])

  useEffect(() => {
    if (!sessionId || !enabled) return undefined

    function report(type: AntiCheatSignalType) {
      const flushed = flushRef.current ? Promise.resolve(flushRef.current()) : Promise.resolve()
      void flushed
        .catch(() => {
          // A failed flush is not a reason to withhold the anti-cheat
          // signal itself -- report proceeds either way.
        })
        .then(() => examApi.reportEvent(sessionId as string, type))
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
