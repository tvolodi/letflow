# GUI review: `template-update-conflict-resolution` (PW-01)

Date: 2026-09-20
Agent: ORCH
Sweep position: 10th of ~15 scenarios in today's systematic GUI-review sweep.
Scenario: `test/fixtures/uat/scenarios/platform/template-update-conflict-resolution.yaml`
Process applied: "review real screens before writing a blind Playwright spec"
(same process as the earlier scenarios in this sweep, e.g.
`gui-review-2026-09-20-partition-retention-drop.md`).

## Outcome: BLOCKED / UNBUILT_FEATURE

The scenario's own stale NOTE (ISS-0527) already flagged its `pipeline_test`
(`web/tests/e2e/pipelines/template-update-conflict.pipeline.e2e.spec.ts`) as
an aspirational forward-reference to a Playwright spec that was never
authored, gated on the same missing feature the scenario's steps exercise.
Per this run's instructions, that note was verified independently rather
than trusted — by reading current `lib/letflow/` and `web/src/` source
directly — not assumed. The feature turns out to be missing more deeply and
in more layers than the note itself implies.

## What was checked, and what it showed

**Does a solution-pack update three-way diff exist?**
Yes, partially. REQ-041 (status: `done`) built:
- Schema: `Letflow.Definitions.SolutionPackInstall`,
  `Letflow.Definitions.SolutionPackArtefactBase`, and
  `Letflow.Definitions.PackUpdateResolution` (each backed by a real
  migration, e.g.
  `priv/repo/migrations/20260817083803_create_pack_update_resolutions.exs`).
- A pure classifier: `Letflow.Definitions.compute_pack_update_plan/5` and
  `classify_artefact/3` (`lib/letflow/definitions.ex`), which correctly
  produces the scenario's own four groups (unchanged / clean_update /
  local_only / conflict) given already-loaded `base`/`theirs`/`incoming`
  content, per the design's truth table
  (`lib/letflow/design/req041-pack-update-diff-schema.md` §5.3).

**Does anything ever populate the tables the classifier reads?**
No. REQ-041's own design doc (§1's "Not built here" table) states in its
own words that "the actual solution-pack export/install path that populates
`solution_pack_installs`/`solution_pack_artefact_bases` from a real install
event" is owned by "SOL-01/02/03 (`src/solution/`, not scoped to any stage
yet)". Grepping `lib/` confirms this: no caller anywhere inserts a
`SolutionPackInstall` or `SolutionPackArtefactBase` row. Both tables are
permanently empty in every real deployment, including for
`Letflow.Packs.Bilimbaga`, the real installed pack used earlier in today's
sweep.

**Does an update-review or apply API exist?**
No. `lib/letflow/routers/solution_packs.ex` has no route that computes and
returns an update-review summary, accepts a per-artefact conflict
resolution, or applies an update while blocking on unresolved conflicts.
`PackUpdateResolution`'s own moduledoc says explicitly: "the actual
conflict-resolution UI/API flow" that inserts a resolution row "is
explicitly out of REQ-041's scope" — `insert_changeset/2` exists only as
scaffolding for a future write path, never called.

**Does a pack-update review screen exist in `web/src/`?**
No. Grepping `web/src/` for update-review/pack-update/conflict-resolution
screens returned no relevant hits. The one plausible hit,
`web/src/components/ui/ConflictResolver.tsx`, was read in full and is
confirmed unrelated — a generic three-action modal (Refetch latest / Merge
manually / Discard mine) surfaced on a `409` optimistic-concurrency write
conflict for a *single record's own edit form* (RND-UI-06), with no
solution-pack, artefact, or install concept anywhere in it.

## Conclusion

The feature genuinely does not exist end-to-end. It is layered more deeply
than the scenario's own NOTE implies: even the *prerequisite* to a
update-review screen — a real write path that records what was installed
and its artefacts' content at install time — was never built. Nothing was
driven against `https://qa.bizdala.com`; there is no real screen, and no
real API response beyond a 404/`no route matched`, to drive or screenshot.

## Filed

Three requirements in `docs/requirements.yaml`, split by layer (matching
this sweep's precedent for architecturally significant, multi-layer gaps,
e.g. REQ-376/REQ-377):

- **REQ-379** (owner `ELIXIR-DEV`, stage S2, status `pending`,
  `depends_on: [REQ-041]`) — the install-time write path that populates
  `solution_pack_installs`/`solution_pack_artefact_bases` when a pack is
  installed, including the requirement that re-installing the same version
  never overwrites an existing base snapshot for an artefact the tenant has
  since adapted.
- **REQ-380** (owner `ELIXIR-DEV`, stage S2, status `pending`,
  `depends_on: [REQ-379]`) — the update-review and apply API: a route
  returning the four-way classification (EO-001), an apply route that
  refuses and names the specific unresolved artefact when a conflict has no
  recorded resolution (EO-002), attributed `keep_local`/`take_incoming`
  persistence via `PackUpdateResolution.insert_changeset/2` (EO-003/EO-004),
  and a baseline shift on apply so a resolved artefact is not re-flagged on
  a later update-review call (EO-005).
- **REQ-381** (owner `FRONTEND-DEV`, stage S8, status `pending`,
  `depends_on: [REQ-380]`) — the review screen itself, reachable from the
  company's pack screen, wired to REQ-380's real endpoints with no mock
  data, including authoring and passing this scenario's own named
  `pipeline_test` once a real screen exists to write it against.

## Fixed vs filed

Nothing was fixed in this dispatch. There is no existing broken screen or
small defect to patch — the entire mechanism (install-tracking write path,
review/apply API, review screen) is absent, and building even the first
layer is a multi-file backend requirement in its own right, not a
same-dispatch fix. All three gaps are filed as appropriately-sized,
dependency-chained requirements rather than attempted inline.

## Status housekeeping

- Scenario fixture's `pipeline_test` NOTE block extended (not removed — the
  feature is not real) with a dated addendum citing REQ-379/REQ-380/REQ-381
  and this report.
- `docs/status/requirement_status.v20.yaml` — appended a `SCOPE-CHANGE` done
  event (`2026-09-20T02:10:24Z`) recording this finding; volume now at 13
  entries / 847 lines / 54294 bytes, well under the roll ceiling.
- `docs/status/requirement_status.index.yaml` — volume 20's entry count and
  note updated to reflect the new append.
- Verified `mix letflow.check_req_id_collision` (OK, no collision) and
  `mix letflow.check_requirements_registration` (348 entries = 346
  registered + 2 deferred + 0 neither + 0 unclassified, no new gate
  failures) both pass with REQ-379/REQ-380/REQ-381 in place.
- Ran `mix letflow.check_issue_refs` before filing anything, per this run's
  instructions: it reports one pre-existing violation
  (`docs/issues/ISS-0728-exam-title-object-object-sibling-wip-rescued.yaml`'s
  `id:` not matching its filename) that belongs to a concurrent sibling
  session's own WIP file (visible untracked in git status at session start)
  — not introduced by this dispatch, and no issue file was touched here.

## Spec status

No permanent Playwright regression spec was authored — there is no shipped
screen to write one against. `web/tests/e2e/pipelines/
template-update-conflict.pipeline.e2e.spec.ts` remains unauthored, now
explicitly the responsibility of REQ-381's acceptance criteria once the
feature ships.
