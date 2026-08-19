# Design: ISS-0061 — migration version collision fix

## Issue

`priv/repo/migrations/20260819000001_create_groups_tenant_scoped.exs` (REQ-063,
part of the internally-ordered sequence 20260819000001–20260819000004) and
`priv/repo/migrations/20260819000001_drop_transition_events.exs` (REQ-046,
standalone) both merged to `main` independently using the same version number
`20260819000001`. Ecto's migration runner rejects duplicate versions outright
(`Ecto.MigrationError: migration version 20260819000001 is duplicated`),
blocking `mix ecto.migrate` and `mix test` (which migrates the sandbox DB
before any test runs) for every host on this backlog.

Diagnosis (ISSUE-FIXER, WF-03 Step 1) confirmed by grep: no other file in the
repo references `20260819000001_drop_transition_events.exs` by filename, and
nothing references its module name `Letflow.Repo.Migrations.DropTransitionEvents`
outside the file itself. The fix is a pure rename — no schema, code, or logic
change.

## Change

Rename one file, byte-for-byte content unchanged:

```
git mv priv/repo/migrations/20260819000001_drop_transition_events.exs \
       priv/repo/migrations/20260819000005_drop_transition_events.exs
```

- File contents: unchanged. In particular the module name stays
  `Letflow.Repo.Migrations.DropTransitionEvents` — Ecto migration module names
  do not need to match the version/timestamp prefix, only the leading numeric
  version in the filename must be unique and Ecto reads the version from the
  filename, not the module name. No edit inside the file is required or
  permitted.
- No other file changes. No new modules, functions, schemas, or migrations are
  introduced by this fix.

## Why `20260819000005`

Existing versions around the collision, in order:

```
20260819000001_create_groups_tenant_scoped.exs        (REQ-063, seq 1/4)
20260819000001_drop_transition_events.exs              (REQ-046, COLLIDES — being renamed)
20260819000002_create_tenant_role_tenant_scoped.exs    (REQ-063, seq 2/4)
20260819000003_create_users_tenant_scoped.exs          (REQ-063, seq 3/4)
20260819000004_drop_legacy_public_identity_tables.exs  (REQ-063, seq 4/4)
20260820000001_drop_tenant_id_events.exs               (next day's sequence starts)
```

REQ-063's four files (`...000001_create_groups_tenant_scoped` through
`...000004_drop_legacy_public_identity_tables`) form an internally-ordered
migration sequence — each depends on schema state left by the prior one — so
none of 000001–000004 may be reassigned without renumbering all four and
breaking that internal ordering for no benefit. `20260819000005` is the next
free slot after that sequence and still falls before the `20260820000001`
sequence begins, which:

- avoids renumbering any file in the REQ-063 sequence,
- keeps `drop_transition_events` inside the `20260819` day-bucket it was
  originally merged under (closest to true chronological merge order, per the
  diagnosis), and
- does not collide with, or need to shift, any `20260820*` file.

## Acceptance criteria mapping

Per `docs/issues/ISS-0061.yaml`, the fix criterion is that `mix ecto.migrate`
and `mix test` no longer fail with `Ecto.MigrationError` on duplicate version
20260819000001. This maps directly to the rename above: after it, every
migration filename in `priv/repo/migrations/` has a unique leading version
number, which is Ecto's sole uniqueness requirement — no other condition
applies.

## Interfaces / schema / state

None. No `@spec`, no Ecto schema field list, no gen_statem shape, no DB table
change — the migration's own `up`/`down` bodies (creating the
`transition_events` drop) are unchanged and out of scope for this design.

## Cross-module dependencies

None introduced. The renamed file continues to run in the same relative
position in the migration sequence (still before `20260820*`), so no
downstream migration's assumptions about prior schema state change.

## Invariants

- Every migration filename's leading version number is globally unique across
  `priv/repo/migrations/`.
- REQ-063's four-file sequence (000001–000004) keeps its internal file order
  and content untouched.
- File content of the renamed migration is byte-for-byte identical to its
  pre-rename content.

## Open questions

None. This is a filename-only rename with no ambiguity in scope, target name,
or content.
