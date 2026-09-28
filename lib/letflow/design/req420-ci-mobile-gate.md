# Design: REQ-420 — CI Mobile gate job — `.github/workflows/ci.yml`

Status: design, not yet implemented. Target file: `.github/workflows/ci.yml`.
Owner of implementation: MOBILE-DEV (per REQ-420's own text and REQ-417's write-scope
widening — the job runs `flutter`, which only MOBILE-DEV's capability row covers; REQ-138
precedent: FRONTEND-DEV, not ELIXIR-DEV, added the frontend job for the same reason).

## 0. Scope and risk framing

This is infrastructure-as-config, same class as REQ-136/REQ-138/ISS-0591/ISS-0592 before
it — per `.claude/agents/code-designer.md`'s stated exception for CI YAML, this design
shows literal target YAML rather than abstracting away from it, because the YAML *is*
the design here.

**SECURITY-REVIEWER scope**: out of scope. No tenant-data path touched (no API route, no
migration, no secret, no response shaping) — CI job wiring only.

**REVIEWER scope**: the same property that mattered for ISS-0591/ISS-0592 matters here,
restated precisely because this change sits directly beside it: `backend` and `frontend`
are the only two required-status-check contexts today
(`docs/migration/decisions/0018-branch-protection-posture.md`). This design **does not
add `mobile` as a third required context** — that is explicitly out of scope per REQ-420's
own text (a 0018 amendment, owned by REVIEWER/ORCH, not this requirement). Consequently
the failure mode that made `backend`/`frontend`'s job-level `if:` so load-bearing
(a required-but-not-reported context permanently blocking `main`) does not yet apply to
`mobile` — but this design still follows the exact same job-level/step-level `if:`
pattern as `backend`/`frontend` anyway, per REQ-420's explicit instruction ("job-level
`if: ${{ !cancelled() }}` (NOT always(), NOT a job-level path condition — same reasoning
as backend/frontend")) and so that `mobile` is *already* shaped correctly on the day a
future amendment does make it required, with no rework needed then.

## 1. What changes and why

Three edits to `.github/workflows/ci.yml`, all additive:

1. `changes` job gains a third boolean output, `mobile`, computed the same way
   `backend`/`frontend` already are (push-to-main always true, both fail-safe branches
   always true, fallback step always true, diff branch via its own regex). No existing
   `backend`/`frontend` line changes.
2. A new sibling job `jobs.mobile`, structurally parallel to `jobs.backend`/`jobs.frontend`
   (needs: changes; `if: ${{ !cancelled() }}`; step-level fail-open `if:` on the expensive
   steps only).
3. `mobile` is **not** added to `path-filter-outputs.txt` (REQ-420's own text: "cd.yml does
   not deploy mobile" — that file exists solely for `cd.yml`'s QA-deploy gating, which has
   no mobile deployment target yet).

## 2. `changes` job — exact new/changed lines

All four locations named in REQ-420's text, shown as the complete surrounding block so
placement is unambiguous. Every line not shown below (the `outputs:` map's existing
`backend`/`frontend` entries, the `frontend` regex, the fallback step's existing
`backend=true`/`frontend=true` lines, `path-filter-outputs.txt` writing) is **unchanged**.

### 2a. `outputs:` map — add `mobile`

```yaml
    outputs:
      backend: ${{ steps.filter.outputs.backend || steps.fallback.outputs.backend }}
      frontend: ${{ steps.filter.outputs.frontend || steps.fallback.outputs.frontend }}
      mobile: ${{ steps.filter.outputs.mobile || steps.fallback.outputs.mobile }}
```

### 2b. Push-to-main branch (inside the `filter` step's `run:` block)

Current text (unchanged lines shown for placement):

```yaml
          if [ "${{ github.event_name }}" = "push" ]; then
            echo "Push to main -- always running both gates (ISS-0840: path filter on push-to-main caused false-green)."
            echo "backend=true" >> "$GITHUB_OUTPUT"
            echo "frontend=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
```

New text (one line added, comment wording adjusted from "both gates" to "all gates" since
there are now three — not a behavior change, just keeping the log line honest):

```yaml
          if [ "${{ github.event_name }}" = "push" ]; then
            echo "Push to main -- always running all gates (ISS-0840: path filter on push-to-main caused false-green)."
            echo "backend=true" >> "$GITHUB_OUTPUT"
            echo "frontend=true" >> "$GITHUB_OUTPUT"
            echo "mobile=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
```

### 2c. Fail-safe branch 1 — no usable base SHA

Current:

```yaml
          if [ -z "$BASE_SHA" ] || [ -z "$HEAD_SHA" ] || [ "$BASE_SHA" = "$ZERO_SHA" ]; then
            echo "No usable base SHA for event '${{ github.event_name }}' (base='$BASE_SHA') -- assuming everything changed."
            echo "backend=true" >> "$GITHUB_OUTPUT"
            echo "frontend=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
```

New:

```yaml
          if [ -z "$BASE_SHA" ] || [ -z "$HEAD_SHA" ] || [ "$BASE_SHA" = "$ZERO_SHA" ]; then
            echo "No usable base SHA for event '${{ github.event_name }}' (base='$BASE_SHA') -- assuming everything changed."
            echo "backend=true" >> "$GITHUB_OUTPUT"
            echo "frontend=true" >> "$GITHUB_OUTPUT"
            echo "mobile=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
```

### 2d. Fail-safe branch 2 — base SHA unreachable after targeted fetch

Current:

```yaml
          if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
            echo "Base SHA $BASE_SHA not reachable even after a targeted fetch (likely a force-push rewrite) -- assuming everything changed."
            echo "backend=true" >> "$GITHUB_OUTPUT"
            echo "frontend=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
```

New:

```yaml
          if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
            echo "Base SHA $BASE_SHA not reachable even after a targeted fetch (likely a force-push rewrite) -- assuming everything changed."
            echo "backend=true" >> "$GITHUB_OUTPUT"
            echo "frontend=true" >> "$GITHUB_OUTPUT"
            echo "mobile=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
```

### 2e. Diff branch — new mobile regex (added after the existing frontend regex, which is unchanged)

Current (unchanged, shown for placement):

```yaml
          if echo "$CHANGED" | grep -qE '^(web/|\.github/workflows/ci\.yml)'; then
            echo "frontend=true" >> "$GITHUB_OUTPUT"
          else
            echo "frontend=false" >> "$GITHUB_OUTPUT"
          fi
```

New block appended immediately after it:

```yaml
          if echo "$CHANGED" | grep -qE '^(apps/mobile/|\.github/workflows/ci\.yml)'; then
            echo "mobile=true" >> "$GITHUB_OUTPUT"
          else
            echo "mobile=false" >> "$GITHUB_OUTPUT"
          fi
```

Regex is exactly the one REQ-420 specifies: `^(apps/mobile/|\.github/workflows/ci\.yml)`.
No change to the `backend` regex (`^(lib/|priv/repo/migrations/|test/|mix\.exs|mix\.lock|\.tool-versions|config/|\.github/workflows/ci\.yml)`)
or the `frontend` regex (`^(web/|\.github/workflows/ci\.yml)`) — both stay byte-for-byte
as today, satisfying AC2's "no changed line inside backend/frontend" bar (the regex
strings live inside the shared `changes` job's script, not inside `jobs.backend`/
`jobs.frontend` themselves, but REQ-420's instruction is explicit that they must not
change either, and this design does not touch them).

### 2f. Fallback step — add `mobile=true`

Current:

```yaml
      - name: Fail-safe defaults if path detection did not complete cleanly
        id: fallback
        if: steps.filter.outcome != 'success'
        run: |
          echo "Path-detection step outcome was '${{ steps.filter.outcome }}', not 'success' -- defaulting to running both gates in full rather than risking a silent skip."
          echo "backend=true" >> "$GITHUB_OUTPUT"
          echo "frontend=true" >> "$GITHUB_OUTPUT"
```

New:

```yaml
      - name: Fail-safe defaults if path detection did not complete cleanly
        id: fallback
        if: steps.filter.outcome != 'success'
        run: |
          echo "Path-detection step outcome was '${{ steps.filter.outcome }}', not 'success' -- defaulting to running all gates in full rather than risking a silent skip."
          echo "backend=true" >> "$GITHUB_OUTPUT"
          echo "frontend=true" >> "$GITHUB_OUTPUT"
          echo "mobile=true" >> "$GITHUB_OUTPUT"
```

### 2g. `path-filter-outputs.txt` step — unchanged, verbatim

Per REQ-420's explicit instruction ("Do not add mobile to path-filter-outputs.txt —
cd.yml does not deploy mobile"), this step is **not** touched:

```yaml
      - name: Write path-filter outputs for cd.yml
        run: |
          echo "backend=${{ steps.filter.outputs.backend || steps.fallback.outputs.backend }}" >> path-filter-outputs.txt
          echo "frontend=${{ steps.filter.outputs.frontend || steps.fallback.outputs.frontend }}" >> path-filter-outputs.txt
          cat path-filter-outputs.txt
```

## 3. New `jobs.mobile` — complete verbatim block

Placed as a sibling after `jobs.frontend` (order in the file does not affect execution —
`needs: changes` is what creates the dependency — but keeping declaration order
`changes` → `backend` → `frontend` → `mobile` matches the requirement sequence
REQ-136 → REQ-138 → REQ-420).

```yaml
  # REQ-420: Mobile gate job, appended alongside `backend`/`frontend` as a sibling under
  # the same `on:` triggers, touching none of their keys. Structurally parallel to
  # `backend`/`frontend` (needs: changes; `if: ${{ !cancelled() }}`; step-level fail-open
  # `if:` on the expensive steps only) per ISS-0591/ISS-0592's design
  # (lib/letflow/design/iss0591-iss0592-ci-dedup-path-filter.md) even though this job is
  # NOT (yet) a required-status-check context.
  #
  # OPEN QUESTION (not resolved by this requirement): whether "Mobile gate (flutter
  # analyze + test + build)" becomes a third required status-check context on `main` per
  # docs/migration/decisions/0018-branch-protection-posture.md. That is a 0018 amendment
  # and belongs to REVIEWER/ORCH, not to REQ-420. This job is only made *eligible* to be
  # named a required context later: it always runs (job-level `if: ${{ !cancelled() }}`,
  # never a job-level path condition) and its internal steps are gated fail-open
  # (`!= 'false'`), so a required context naming this job's `name:` would never be
  # reported missing the way a job-level path filter would cause. See 0018's own
  # `backend`/`frontend` job-header comments for the precedent this follows.
  mobile:
    name: Mobile gate (flutter analyze + test + build)
    runs-on: ubuntu-latest
    needs: changes
    # NOT `always()` -- same reasoning as `backend`/`frontend` (see this design's §3 and
    # the ISS-0591/ISS-0592 design doc's job-block note): `!cancelled()` keeps this job
    # running when `changes` merely *fails* (fail open), while still letting a genuinely
    # cancelled/superseded run (this workflow's own `cancel-in-progress`) actually stop.
    if: ${{ !cancelled() }}
    defaults:
      run:
        working-directory: apps/mobile

    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Set up Java (Temurin 17)
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"

      - name: Set up Flutter
        uses: subosito/flutter-action@v2
        with:
          flutter-version-file: apps/mobile/pubspec.yaml
          cache: true

      - name: Install dependencies
        if: needs.changes.outputs.mobile != 'false'
        run: flutter pub get

      - name: Analyze
        if: needs.changes.outputs.mobile != 'false'
        run: flutter analyze

      - name: Test
        if: needs.changes.outputs.mobile != 'false'
        run: flutter test

      - name: Build debug APK
        if: needs.changes.outputs.mobile != 'false'
        run: flutter build apk --debug
```

Notes on each element, mapped to REQ-420's text:

- **`name: Mobile gate (flutter analyze + test + build)`** — exact string REQ-420
  specifies. AC1 checks this literal string.
- **`runs-on: ubuntu-latest`** — as specified; matches `backend`/`frontend`.
- **`needs: changes`** — as specified.
- **`if: ${{ !cancelled() }}`** — exact expression REQ-420 specifies (not `always()`, not
  a job-level path condition). AC1 checks this literal string.
- **`defaults: run: working-directory: apps/mobile`** — as specified; mirrors
  `frontend`'s `working-directory: web` pattern.
- **`actions/checkout@v4`** — no `fetch-depth: 0` needed here (unlike `changes`'s own
  checkout, this job never runs `git diff`/`git fetch` against history); matches
  `frontend`'s plain checkout, not `backend`'s/`changes`'s full-history one.
- **`actions/setup-java@v4`, Temurin 17`** — REQ-420's explicit requirement (Flutter's
  Android toolchain needs a JDK; Temurin 17 is the version Flutter's own Android Gradle
  Plugin generation for this project's `android/app/build.gradle` targets — consistent
  with the `minSdk 26`/current AGP baseline REQ-419 already set up).
- **`subosito/flutter-action@v2`, `flutter-version-file: apps/mobile/pubspec.yaml`,
  `cache: true`** — exact inputs REQ-420 specifies. `pubspec.yaml`'s `environment:
  flutter: "3.41.7"` (confirmed present, line 23) is what this action reads to pin the
  Flutter SDK version installed in CI to the same one REQ-419 pinned locally — no
  separate hardcoded version in `ci.yml` to drift from `pubspec.yaml`, the same
  single-source-of-truth pattern `backend`'s `.tool-versions`/`version-file:` already
  uses.
- **Four flutter steps, each `if: needs.changes.outputs.mobile != 'false'`** — exact
  fail-open condition form REQ-420 specifies (`!= 'false'`, matching `backend`/
  `frontend`'s existing steps, not `== 'true'` — same empty-string-on-upstream-failure
  reasoning as ISS-0591/ISS-0592 design §4's fail-open note applies unchanged here).
  `flutter pub get` runs first (unconditional dependency install is not separated from
  the gated steps here, unlike `backend`'s cache-then-conditional-install split, because
  `subosito/flutter-action`'s own `cache: true` already caches the Flutter SDK itself;
  `pub get`'s own package cache is comparatively cheap and gating it consistently with
  the other three keeps all "expensive-ish" steps under one condition rather than
  splitting hairs over which sub-step is cheap enough to run unconditionally).

## 4. Verbatim mapping to REQ-420's ownership/scope note

- Owner: MOBILE-DEV per REQ-420's text and REQ-417's write-scope widening. This design
  does not authorize any other agent to implement it.
- `jobs.backend` and `jobs.frontend`: **no keys change** — confirmed by this design's §2
  (only `changes`'s script and outputs gain lines) and §3 (mobile is a pure new sibling
  job). No line inside `steps:`, `services:`, `runs-on:`, `if:`, or `name:` of either
  existing job is touched.

## 5. Acceptance-criteria mapping

1. **AC1** (`python -c "..."` prints job list, mobile job name, mobile `if`) — §3's job
   block gives the exact `name:` (`Mobile gate (flutter analyze + test + build)`) and
   `if:` (`${{ !cancelled() }}`) strings; adding `mobile` as a sibling under `jobs:`
   alongside unchanged `backend`/`frontend`/`changes` produces the sorted list
   `['backend', 'changes', 'frontend', 'mobile']`.
2. **AC2** (`git diff origin/main -- ci.yml` shows only additions, no backend/frontend
   line changed, regexes untouched) — §2 shows every changed/added line is either a new
   `echo "mobile=..."` line inserted alongside existing `backend=`/`frontend=` lines
   (additions, not edits to those existing lines) or the new §2e regex block (a pure
   addition after the existing frontend regex block); §3's job is a pure addition; §4
   states explicitly no backend/frontend key changes. Implementer verifies via real
   `git diff` output and quotes it in their handoff, per this design's instruction — this
   design does not fabricate that output itself.
3. **AC3** (every flutter step has the fail-open `if:`, changes job emits mobile=true on
   push/both fail-safes/fallback) — §2b/2c/2d/2f each show the added `mobile=true` line;
   §3's four flutter steps each carry `if: needs.changes.outputs.mobile != 'false'`
   verbatim.
4. **AC4** (PR run shows all four flutter steps succeeding, quoted from `gh run view
   --json jobs`) — implementer's job once this design is built and pushed; not
   satisfiable at design time (no CI run exists yet). Flagged, not silently resolved.
5. **AC5** (backend/frontend gates' conclusions unchanged on this PR, quoted from `gh pr
   checks`) — follows directly from §4's "no keys change" guarantee, but is itself a
   live-CI verification the implementer must run and quote, same as AC4.
6. **AC6** (header comment records the 0018 question as open) — §3's job comment block
   states the open question verbatim, matching REQ-420's own wording ("belongs to
   REVIEWER/ORCH, not to this requirement").

## 6. Open questions (flagged, not resolved here)

- **0018 required-context amendment.** Restated per REQ-420's own instruction: whether
  `Mobile gate (flutter analyze + test + build)` becomes a third required status-check
  context is out of scope for this requirement and belongs to a future 0018 amendment
  owned by REVIEWER/ORCH. This design only makes the job eligible (§3's header comment
  records this explicitly, satisfying AC6).
- **Temurin 17 exact match to the Android toolchain.** This design follows REQ-420's
  explicit instruction verbatim; it does not independently re-derive whether Temurin 17
  is the minimum/exact JDK version `apps/mobile/android/app/build.gradle`'s current AGP
  version requires. If `flutter build apk --debug` fails in CI over a JDK-version
  mismatch, that is a live-CI finding for the implementer to resolve (likely a JDK bump,
  not a design change), not an error in this design's literal instruction-following.
- **`flutter pub get` gating.** As noted in §3's step-by-step notes, this design gates
  `flutter pub get` under the same fail-open condition as the other three steps rather
  than leaving it unconditional (the way `backend`'s Elixir/Rust setup steps stay
  unconditional while only `mix deps.get`/`mix letflow.check` are gated). REQ-420's text
  lists all four flutter steps under one `if:` instruction without carving out `pub get`
  as unconditional, so this design follows that literal grouping; flagged in case
  REVIEWER prefers splitting it out to more closely mirror `backend`'s pattern.
