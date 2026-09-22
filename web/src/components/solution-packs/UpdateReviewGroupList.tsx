/** UpdateReviewGroupList — REQ-381 design §4.3
 *
 *  Presentational. Partitions `entries` into the four `classification` wire
 *  values (EO-001, §4.3.1), sub-partitions `both_sides_conflict` into
 *  resolved/needs-a-decision (EO-002/EO-005, §4.3.2), and shows session-local
 *  attribution once an apply has succeeded (EO-003, §4.3.4). No content
 *  diff — the review response does not return `base`/`theirs`/`incoming`
 *  content (REQ-380 design §3.2's own scope fence), so this screen shows
 *  classification/status only, per design §4.3.1.
 */
import React from 'react'
import type { PackResolutionChoice, PackUpdateAppliedEntry, PackUpdateReviewEntry } from '@/api/solutionPacks'
import { formatDateTime } from '@/i18n/format'

export interface UpdateReviewGroupListProps {
  entries: PackUpdateReviewEntry[]
  resolutionChoices: Map<string, PackResolutionChoice>
  onChooseResolution: (artefactType: string, artefactId: string, choice: PackResolutionChoice) => void
  attribution: Map<string, { resolvedBy: string; resolvedAt: string }>
  appliedEntries: PackUpdateAppliedEntry[] | null
}

export function artefactKey(artefactType: string, artefactId: string): string {
  return `${artefactType}:${artefactId}`
}

const GROUP_LABELS: Record<PackUpdateReviewEntry['classification'], string> = {
  unchanged: 'Unchanged',
  safe_to_update: 'Safe to update',
  local_only: "Your own change",
  both_sides_conflict: 'Changed on both sides',
}

function EntryRow({ entry }: { entry: PackUpdateReviewEntry }): React.ReactElement {
  return (
    <div
      data-testid="update-review-entry"
      data-artefact-id={entry.artefact_id}
      style={{ padding: '.4rem 0', borderBottom: '1px solid var(--border-default)', fontSize: '.85rem', display: 'flex', gap: '.75rem' }}
    >
      <span data-testid="update-review-entry-type" style={{ color: 'var(--text-secondary)' }}>{entry.artefact_type}</span>
      <span data-testid="update-review-entry-id" style={{ fontFamily: 'var(--font-mono)' }}>{entry.artefact_id}</span>
    </div>
  )
}

function ResolutionControl(props: {
  entry: PackUpdateReviewEntry
  choice: PackResolutionChoice | undefined
  onChoose: (choice: PackResolutionChoice) => void
}): React.ReactElement {
  const { entry, choice, onChoose } = props
  return (
    <div
      data-testid="update-review-resolution-control"
      data-artefact-id={entry.artefact_id}
      style={{ padding: '.5rem 0', borderBottom: '1px solid var(--border-default)', display: 'flex', flexDirection: 'column', gap: '.35rem' }}
    >
      <div style={{ display: 'flex', gap: '.75rem', alignItems: 'center', fontSize: '.85rem' }}>
        <span style={{ color: 'var(--text-secondary)' }}>{entry.artefact_type}</span>
        <span style={{ fontFamily: 'var(--font-mono)' }}>{entry.artefact_id}</span>
      </div>
      <div role="radiogroup" aria-label={`Resolution for ${entry.artefact_id}`} style={{ display: 'flex', gap: '.5rem' }}>
        <label style={{ display: 'flex', alignItems: 'center', gap: '.25rem', fontSize: '.8rem' }}>
          <input
            type="radio"
            data-testid="update-review-resolution-keep-local"
            data-artefact-id={entry.artefact_id}
            name={`resolution-${entry.artefact_type}-${entry.artefact_id}`}
            checked={choice === 'keep_local'}
            onChange={() => onChoose('keep_local')}
          />
          Keep ours
        </label>
        <label style={{ display: 'flex', alignItems: 'center', gap: '.25rem', fontSize: '.8rem' }}>
          <input
            type="radio"
            data-testid="update-review-resolution-take-incoming"
            data-artefact-id={entry.artefact_id}
            name={`resolution-${entry.artefact_type}-${entry.artefact_id}`}
            checked={choice === 'take_incoming'}
            onChange={() => onChoose('take_incoming')}
          />
          Take theirs
        </label>
      </div>
    </div>
  )
}

export function UpdateReviewGroupList(props: UpdateReviewGroupListProps): React.ReactElement {
  const { entries, resolutionChoices, onChooseResolution, attribution, appliedEntries } = props

  const groups: Record<PackUpdateReviewEntry['classification'], PackUpdateReviewEntry[]> = {
    unchanged: [],
    safe_to_update: [],
    local_only: [],
    both_sides_conflict: [],
  }
  for (const entry of entries) {
    groups[entry.classification].push(entry)
  }

  const conflictNeedsDecision = groups.both_sides_conflict.filter((e) => !e.resolved)
  const conflictResolved = groups.both_sides_conflict.filter((e) => e.resolved)

  return (
    <div data-testid="update-review-group-list" style={{ display: 'flex', flexDirection: 'column', gap: '1.25rem' }}>
      {(['unchanged', 'safe_to_update'] as const).map((classification) => (
        <div key={classification} data-testid={`update-review-group-${classification}`}>
          <h4 style={{ margin: '0 0 .35rem' }}>
            {GROUP_LABELS[classification]} ({groups[classification].length})
          </h4>
          {groups[classification].map((entry) => (
            <EntryRow key={artefactKey(entry.artefact_type, entry.artefact_id)} entry={entry} />
          ))}
        </div>
      ))}

      <div data-testid="update-review-group-local_only">
        <h4 style={{ margin: '0 0 .35rem' }}>{GROUP_LABELS.local_only} ({groups.local_only.length})</h4>
        {groups.local_only.map((entry) => (
          <EntryRow key={artefactKey(entry.artefact_type, entry.artefact_id)} entry={entry} />
        ))}
      </div>

      <div data-testid="update-review-group-both_sides_conflict">
        <h4 style={{ margin: '0 0 .35rem' }}>
          {GROUP_LABELS.both_sides_conflict} ({groups.both_sides_conflict.length})
        </h4>

        <div data-testid="update-review-conflict-needs-decision">
          <h5 style={{ margin: '.5rem 0 .25rem', color: 'var(--text-secondary)' }}>
            Needs a decision ({conflictNeedsDecision.length})
          </h5>
          {conflictNeedsDecision.map((entry) => (
            <ResolutionControl
              key={artefactKey(entry.artefact_type, entry.artefact_id)}
              entry={entry}
              choice={resolutionChoices.get(artefactKey(entry.artefact_type, entry.artefact_id))}
              onChoose={(choice) => onChooseResolution(entry.artefact_type, entry.artefact_id, choice)}
            />
          ))}
        </div>

        <div data-testid="update-review-conflict-already-resolved">
          <h5 style={{ margin: '.5rem 0 .25rem', color: 'var(--text-secondary)' }}>
            Already resolved ({conflictResolved.length})
          </h5>
          {conflictResolved.map((entry) => {
            const key = artefactKey(entry.artefact_type, entry.artefact_id)
            const attr = attribution.get(key)
            return (
              <div
                key={key}
                data-testid="update-review-resolved-entry"
                data-artefact-id={entry.artefact_id}
                style={{ padding: '.4rem 0', borderBottom: '1px solid var(--border-default)', fontSize: '.85rem' }}
              >
                <div style={{ display: 'flex', gap: '.75rem' }}>
                  <span style={{ color: 'var(--text-secondary)' }}>{entry.artefact_type}</span>
                  <span style={{ fontFamily: 'var(--font-mono)' }}>{entry.artefact_id}</span>
                </div>
                {attr ? (
                  <div data-testid="update-review-resolved-attribution" style={{ color: 'var(--text-secondary)', fontSize: '.8rem' }}>
                    Kept by {attr.resolvedBy} at {formatDateTime(attr.resolvedAt)}
                  </div>
                ) : (
                  <div data-testid="update-review-resolved-attribution-unavailable" style={{ color: 'var(--text-secondary)', fontSize: '.8rem' }}>
                    Resolved by a previous decision (attribution not available — server does not
                    return resolved_by/resolved_at yet)
                  </div>
                )}
              </div>
            )
          })}
        </div>
      </div>

      {appliedEntries && (
        <UpdateAttributionPanel appliedEntries={appliedEntries} attribution={attribution} />
      )}
    </div>
  )
}

/** UpdateAttributionPanel — design §4.3.4 (EO-003) */
function UpdateAttributionPanel(props: {
  appliedEntries: PackUpdateAppliedEntry[]
  attribution: Map<string, { resolvedBy: string; resolvedAt: string }>
}): React.ReactElement {
  const { appliedEntries, attribution } = props
  const keptLocal = appliedEntries.filter((e) => e.action === 'left_unchanged' && e.classification === 'both_sides_conflict')

  return (
    <div data-testid="update-attribution-panel">
      <h4 style={{ margin: '0 0 .35rem' }}>Kept-as-is decisions</h4>
      {keptLocal.length === 0 ? (
        <p style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>None in this session.</p>
      ) : (
        keptLocal.map((entry) => {
          const key = artefactKey(entry.artefact_type, entry.artefact_id)
          const attr = attribution.get(key)
          return (
            <div key={key} data-testid="update-attribution-entry" data-artefact-id={entry.artefact_id} style={{ fontSize: '.85rem', padding: '.25rem 0' }}>
              {entry.artefact_id} kept as-is by {attr?.resolvedBy ?? 'unknown'} at{' '}
              {attr ? formatDateTime(attr.resolvedAt) : 'unknown time'}
            </div>
          )
        })
      )}
    </div>
  )
}
