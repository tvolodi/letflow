# Login-directory pepper: provisioning and rotation

Owner: REQ-443 (decision `docs/migration/decisions/0043-email-first-login-ba-decisions.md` D-C;
design `lib/letflow/design/req434-email-first-login-directory.md` s2.4, s3.9).

The login directory (`tenant_login_directory`) stores `email_key = HMAC-SHA256(pepper, ...)`
plus the `key_id` of the pepper that produced it. The pepper is per environment. This
runbook covers provisioning it, rotating it, and rolling back.

Rules that apply to every step:

- A pepper value never appears in the repository, a chat, a ticket, a handoff, a log or a
  command line. This document contains none and no command that prints one.
- A key id (`[a-z0-9_-]`, 1..32 characters, for example `p2026a`) is a label, not a secret.
  It is stored on every row and is NEVER reused for a different pepper; boot refuses a
  previous id equal to the current id.
- The tasks below print key ids and row counts only. If you ever see an email address, a hex
  or base64 key or a pepper in their output or in a log, stop and treat it as a defect.
- Environment variables (read by `config/runtime.exs`, which refuses to boot on a bad value):
  `LETFLOW_LOGIN_DIRECTORY_PEPPER` and `LETFLOW_LOGIN_DIRECTORY_PEPPER_ID` (current, required);
  `LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS` and `LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS_ID`
  (rotation only: set both or neither, and each must differ from the current one).

## 0. Command forms: Mix versus the release container

Every command below is written in its Mix form (`mix ...`, for dev, CI and any host with the
source tree). **A deployed release container has NO Mix** (verified on QA, 2026-10-05, infra task
T-0154): there the same operations are plain public functions, called through the release's
`rpc` against the RUNNING node (the application and Repo are already started there). Wrap each call
in `IO.inspect()` so the result is printed; `rpc` does not set a process exit code, so read the
printed result (`{:ok, ...}` or `{:error, atom}`) instead of checking an exit status. Output is
key ids and counts only, never an email or a secret.

| Operation | Mix form | Release form (run inside the container) |
|---|---|---|
| Backfill, dry run | `mix letflow.backfill_login_directory --dry-run` | `bin/letflow rpc 'Letflow.LoginDirectory.Backfill.run(dry_run: true) |> IO.inspect()'` |
| Backfill, for real | `mix letflow.backfill_login_directory` | `bin/letflow rpc 'Letflow.LoginDirectory.Backfill.run() |> IO.inspect()'` |
| Key status | `mix letflow.login_directory.key_status` | `bin/letflow rpc 'Letflow.LoginDirectory.KeyRotation.key_status() |> IO.inspect()'` |
| Retire a key id, dry run | `mix letflow.login_directory.retire_key --key-id ID --dry-run` | `bin/letflow rpc 'Letflow.LoginDirectory.KeyRotation.retire_key("ID", dry_run: true) |> IO.inspect()'` |
| Retire a key id, for real | `mix letflow.login_directory.retire_key --key-id ID` | `bin/letflow rpc 'Letflow.LoginDirectory.KeyRotation.retire_key("ID") |> IO.inspect()'` |

The Mix tasks only wrap these functions. `retire_key` refuses the current key id and an absent
key id in both forms (`{:error, :current_key_id}` / `{:error, :not_found}`). Where a later
section says "run X", use the release form on a deployed container.

## 1. First provisioning (per environment)

1. Generate 32 random bytes as 64 hex characters with a local tool, writing the output
   straight into the environment's secrets store entry or a mode-0600 file, never to the
   terminal or shell history. For example `openssl rand -hex 32` redirected to that file.
   It must not be all zeros, not all `f`, and must differ from `LETFLOW_SECRETS_MASTER_KEY`.
2. Choose a key id that has never been used in this environment.
3. Store both in the environment's secrets store (QA/production: the host's `deploy/.env`,
   template `deploy/.env.example`). Leave the two `_PREVIOUS` variables blank.
4. Deploy. The migration creates the table; boot fails closed if either value is missing or
   malformed.
5. Run `mix letflow.backfill_login_directory --dry-run`, then `mix letflow.backfill_login_directory`
   (maintenance window; insert-only). Without it, existing users are undiscoverable.
6. Check `mix letflow.login_directory.key_status`: one key id, marked `(current)`.
7. Do not enable `LETFLOW_LOGIN_DISCOVERY_ENABLED` outside dev until 0042 OQ-3 is resolved.

## 2. Planned rotation

Discovery keeps working throughout: while a previous pepper is configured, lookups try both keys.

1. Generate a new pepper (section 1, step 1) and choose a NEW key id.
2. In the secrets store: move the current pepper and id to
   `LETFLOW_LOGIN_DIRECTORY_PEPPER_PREVIOUS` / `_PREVIOUS_ID`, and set the new pair as
   `LETFLOW_LOGIN_DIRECTORY_PEPPER` / `_ID`. Deploy.
3. Run `mix letflow.backfill_login_directory --dry-run`, then `mix letflow.backfill_login_directory`.
   It writes a row under the new (current) key id for every active user; old rows are left alone.
4. Verify: `mix letflow.login_directory.key_status` shows both ids. The new id's count is
   *expected* to be at least the old id's count, but that is not guaranteed (the old id may
   hold rows for users removed since, and a user without a directory entry makes the
   comparison approximate); treat it as a sanity check, not proof. Re-run the backfill: it must insert 0 rows.
   **Limit of this check:** "every previous-id row has a current-id counterpart" can only be
   eyeballed from these counts. An exact per-row check would require recomputing keys from
   plaintext emails, which no tool here does or should print; the backfill reporting 0
   inserted on a second run is the stronger evidence, because it recomputes every active
   user's current key and finds each already present.
5. Retire the old id: `mix letflow.login_directory.retire_key --key-id OLD_ID --dry-run`, check
   the count equals the old id's count in `key_status`, then run it without `--dry-run`. It
   refuses the current id and an id with no rows.
6. Remove the two `_PREVIOUS` variables from the secrets store. Deploy.
7. `mix letflow.login_directory.key_status` shows only the new id.

## 3. Emergency rotation (suspected pepper exposure)

An exposed pepper lets an attacker test guessed emails against the table, so the old rows
must go quickly, at the cost of availability.

1. Generate a new pepper and a new key id; set them as current. You may skip configuring a
   previous pepper (nothing should keep trusting the exposed one). Deploy.
2. Immediately retire the exposed id: `mix letflow.login_directory.retire_key --key-id EXPOSED_ID`
   (use `--dry-run` first only if time allows).
3. Accepted consequence: until the backfill completes, email discovery returns the neutral
   response (no tenant found) and the SPA falls back to the `?realm=` flow.
4. Run `mix letflow.backfill_login_directory` now, then confirm with
   `mix letflow.login_directory.key_status` that only the new id remains.
5. Remove any leftover `_PREVIOUS` variables; record the incident per the normal process.

## 4. Rollback

- Before retiring (planned rotation, steps 1-4): swap the variables back (old pair current,
  new pair previous) and deploy; lookups find rows under either key. Then retire the NEW id
  with `retire_key` (it is no longer current) when you are sure.
- After retiring: the retired rows are gone and cannot be restored by this tooling. Rolling
  back the configuration alone leaves discovery empty until you run the backfill under the
  restored current pepper, which rebuilds every active user's row. Never reuse a retired id
  for a different pepper; the old pepper may only return under its own old id.
- `retire_key` refuses the current id, so a mistyped current id cannot be deleted.

## 5. EXTERNAL dependency (not in this repository)

The ai-dala-infra repository's `landscape/secrets-inventory.md` needs an entry for
`LETFLOW_LOGIN_DIRECTORY_PEPPER` and `LETFLOW_LOGIN_DIRECTORY_PEPPER_ID` per environment (QA,
production), with owner and a pointer to this runbook as the rotation procedure. That file is
not edited from this repository; the infra owner must add it before the feature is enabled
outside dev (REQ-444).
