# REQ-181 design validation report — CODE-DESIGN-VALIDATOR

**Verdict: PASS (re-check after rework_count 1)**

Design reviewed: `lib/letflow/design/req181-webhooks-core.md`, commit
1e0029e, branch `feature/WF02-REQ181-20260829`.

## Re-check result (rework_count 1 -> re-verification)

`git diff 3e60615 1e0029e -- lib/letflow/design/req181-webhooks-core.md`
shows the *only* change in the entire document is the replacement of
section 2.2's fenced block with prose. The fenced block that previously
read:

```
generate_webhook_secret_plaintext() -> "whsec_" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
hash_webhook_secret(plaintext) -> :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
```

is gone. Section 2.2 (lines 143–181 of the current file) now contains zero
fenced code blocks — only prose naming `:crypto.strong_rand_bytes/1`,
`Base.encode16/2` (`case: :lower`), and `:crypto.hash/2` and describing
their role, without composing them into a literal right-hand-side
expression. This satisfies AC7.

Grepped the whole file for every ` ``` ` fence (22 markers / 11 blocks) and
inspected each: lines 12–36 (wire-contract restatement, plain text), 185–200
(`@type t ::` struct shape), 213–215 and 226–228 (`@spec insert_changeset/2`,
`@spec status_changeset/2`), 253–270 (`@type opts`, `@type create_attrs`,
`@spec create/2`), 314–316 (`@spec list/1`), 345–366 (`@type update_attrs`,
`@spec update/3` x2), 410–415 (`@spec delete/2`), 437–439 (`@spec get/2`).
All eleven blocks are `@spec`/`@type` declarations or the one wire-contract
restatement table — none is a composed function-body expression. No other
instance of the defect class exists in the document.

Per this run's handoff note, the other three previously-confirmed items were
re-confirmed via the diff rather than re-derived from scratch, since the
diff proves they are byte-for-byte unchanged from the prior PASS-eligible
state:

1. **Secret-hashing precedent citation (§2.2, AC2)** — unchanged text,
   still genuine against `lib/letflow/identity.ex`'s `generate_token_plaintext/0`
   / `hash_token_value/1` (confirmed present, same mechanism, on this
   re-check via `grep -n` on `lib/letflow/identity.ex`).
2. **Tenant-scoped migration pattern (§1, AC1)** — unchanged text, no lines
   in this diff.
3. **`update/2` status/is_active reconciliation table (§3.3, AC3)** —
   unchanged text, no lines in this diff.

No new defect found. All prior findings below (from the first-pass review)
still hold as PASS.

## Verdict

PASS. Routed to ELIXIR-DEV via
`handoffs/WF02-REQ181-20260829/step-02a-elixir-dev.json`.

---

# Original (rework_count 0) review — historical record below

Design reviewed at that time: `lib/letflow/design/req181-webhooks-core.md` (commit 3e60615,
branch `feature/WF02-REQ181-20260829`).

## Checks independently verified as correct

1. **Secret-hashing precedent (AC2 / §2.2) — genuine, not fabricated.**
   Read `lib/letflow/identity.ex` directly. `insert_token/3` (line 877),
   `generate_token_plaintext/0` (line 897: `"lf_tok_" <> (:crypto.strong_rand_bytes(32)
   |> Base.encode16(case: :lower))`), and `hash_token_value/1` (line 901:
   `:crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)`) exist
   exactly as the design describes, backing `Letflow.Identity.ApiToken`'s
   `token_hash` column (`lib/letflow/identity/api_token.ex` line 29). Grepped
   `mix.lock`/`lib/letflow/` — no bcrypt/argon2 dependency, and
   `Letflow.Identity.User.password_hash`'s sentinel values (`"__OIDC_ONLY__"`,
   `"__NO_PASSWORD_SET__"`) confirm the design's claim that it sets no real
   hashing precedent. This precedent is real, not invented.

2. **Tenant-scoped migration pattern (AC1 / §1) — genuine.** Read
   `priv/repo/migrations/20260829000001_create_dlq_entries.exs` in full: the
   `if prefix() do ... end` guard, explicit `:binary_id` primary key, no
   index on `tenant_id` alone, and prefix-scoped indexes all match what the
   design claims to mirror. Confirmed `Letflow.TenantProvisioning`'s
   `@tenant_scoped_migration_manifest` (`lib/letflow/tenant_provisioning.ex`
   line 438) already registers `CreateDlqEntries`, substantiating the "both
   halves are mandatory" claim the design repeats for its own migration.

3. **`update/2` status/is_active reconciliation table (§3.3) — complete and
   internally consistent.** Enumerated the input space: single-key
   status/is_active (4 rows), both-agreeing, both-disagreeing, invalid
   status string, and empty attrs — all 7 combinations are covered, all
   `paused_at` side effects are stated (including the idempotent-re-pause
   and clear-only-if-non-nil rules), and no two rows produce contradictory
   outcomes for the same input shape.

## Defect found — AC7 fails

Section 2.2 contains a fenced block that reproduces real `.ex` function
body logic almost verbatim, not a signature or type shape:

```
generate_webhook_secret_plaintext() -> "whsec_" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
hash_webhook_secret(plaintext) -> :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
```

Compare directly against the real implementation this design claims to
mirror, `lib/letflow/identity.ex` lines 897–902:

```elixir
defp generate_token_plaintext do
  "lf_tok_" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
end

defp hash_token_value(plaintext) do
  :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
end
```

The design's block is not a `@spec`/type shape — it states the actual
right-hand-side expressions of both function bodies verbatim (only the
literal prefix `"whsec_"` differs from `"lf_tok_"`, and `do...end` is
flattened to `->`). This is copy-paste-ready Elixir logic, indistinguishable
in substance from the real `.ex` bodies it was copied from. WF-02 Step 1b's
"no fenced code block reproducing real/near-real `.ex` file content —
signatures and type shapes only, no function bodies" rule (AC7) is a
mechanical, no-exceptions rule per this project's own established pattern
(this exact class of defect already forced two rework passes on REQ-157).
Pseudocode syntax (`->` instead of `do...end`) does not exempt a block whose
content is the real function body.

All other fenced blocks in the design (§2.1, §2.3, §2.4, §3.1, §3.2, §3.3,
§3.4, §3.5) are `@spec`/`@type` declarations or plain data tables — no
other function-body content was found.

## Required fix

Replace the §2.2 code block with a prose/table description of the
mechanism (e.g.: "the plaintext is 6 bytes... generated via
`:crypto.strong_rand_bytes/1`, hex-encoded via `Base.encode16/2` with
`case: :lower`, and prefixed with the literal `\"whsec_\"`; the hash is the
SHA-256 digest of the plaintext via `:crypto.hash/2`, also hex-encoded
lowercase") without writing the actual `->`/expression syntax that mirrors
the real function bodies. Naming the functions used (`:crypto.strong_rand_bytes/1`,
`:crypto.hash/2`, `Base.encode16/2`) and their arguments/options is fine;
composing them into the literal expression is not.
