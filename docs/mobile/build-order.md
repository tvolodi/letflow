# Mobile tier — build order

The order [`requirements.md`](requirements.md)'s eight requirements are built
in, and what each waits on. Migrated from R-Co's `docs/addon-2/03-implementation-order.md`
"Track M", with the dependency column re-derived against Letflow.

---

## The sequence

| Order | ID | Title | Priority | Depends on |
|---|---|---|---|---|
| M1 | `MOB-1` | Generic definition-interpreter app shell | MUST | existing definition contracts |
| M2 | `MOB-2` | Tenant bootstrap (slug → config → OIDC PKCE → secure store) | MUST | M1 · **unauthenticated `tenant-config`** |
| M3 | `MOB-5` | On-device security (secure token storage, no cleartext) | MUST | M2 |
| M4 | `MOB-3` | Offline definition cache + delta sync + version pinning | MUST | M2 · **`GET /definitions/delta`** · **`{form_id, form_version}` on task payloads** |
| M5 | `MOB-4` | Generic renderers + six mandatory states | MUST | M4 · form/list/task APIs |
| M6 | `MOB-6` | API client (auth / refresh / retry / typed errors) | SHOULD | M2 |
| M7 | `MOB-7` | i18n (reuse the SPA's locale policy) | SHOULD | M5 · a stated platform locale policy |
| M8 | `MOB-8` | Enforce the v1 scope boundary | MUST | M5 |

`MOB-5` is sequenced third, immediately after bootstrap, and not left to a
hardening phase. Token storage is decided the moment the first token exists;
retrofitting secure storage after three screens already read from plain
preferences is a rewrite, not a fix.

## Where this diverges from R-Co's plan

R-Co's ordering principle #4 read: *"Mobile is an independent track. It depends
only on existing server contracts, so it runs in parallel with the entire
backend sequence from day one."*

**That does not transfer.** It was true for R-Co because R-Co's backend was
already shipped — "existing server contracts" existed. Letflow's do not yet: all
three of the tier's backend touch-points are gaps as of 2026-08-21
([`architecture.md`](architecture.md) §3). Restating "parallel from day one" here
would be copying a conclusion while dropping the premise that produced it.

The corrected picture:

- **M1 can start once the definition contract is stable** — it renders whatever
  the server sends, so it needs the format, not the endpoints.
- **M2 blocks on the unauthenticated tenant-config gap.** This is the gate for
  the whole tier: without it the app cannot reach a login screen.
- **M4 blocks on two further gaps** (delta sync, pinned form versions), one of
  which (`/definitions/delta`) is genuinely new backend work rather than a port
  of anything in R-Co.

So S9 depends on S4, and within S9 the useful parallelism is M1 against the
backend gap-closing work, not the whole track against the whole backend.

## Phasing

| Phase | Work | Gate |
|---|---|---|
| **M-0** | Close the three backend gaps (S4/S9 boundary work) | Each endpoint reachable and contract-tested from `mix test` |
| **M-1** | M1, M2, M3 — shell, bootstrap, security | A build authenticates two distinct tenants and stores tokens securely |
| **M-2** | M4, M6 — cache and API client | Airplane-mode launch renders cached definitions; pinned versions never substitute |
| **M-3** | M5, M7, M8 — renderers, i18n, scope gate | All six renderer states demonstrable, including a forced `429` |

M-0 is not optional preamble. It is the majority of the risk, it is backend
work, and it is the part that a mobile-shaped estimate will silently omit.
