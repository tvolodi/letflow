# 0003 — Ecto schema/migration strategy

Status: pending (REQ-012). Owner: ELIXIR-DEV.

## Question

R-Co has 143 Postgres migrations under `migrations/`. Does Letflow port
the existing SQL schema as Ecto migrations 1:1 (preserving
table/column names for easier cross-referencing during the port), or
redesign it Ecto-idiomatically? How is multi-tenancy represented at
the schema level? R-Co's own tenant-modeling design is documented in
its `src/design/`:

- `adp-01-tenant-column-event-store.md`
- `adp-02-tenant-columns-definition-instance-audit.md`
- `adp-03-tenant-context-resolution-api.md`
- `adp-04-user-tenant-binding.md`
- `adp-04a-external-identity-linkage-user.md`
- `adp-04b-tenant-realm-binding.md`

Read these before deciding whether Letflow adopts R-Co's tenant-column
approach or diverges from it.

## Decision

_Not yet recorded — REQ-012 fills this in._

## Reasoning

_Must explicitly address: 1:1 port vs. redesign, with reasoning; which
adp-0x doc(s) were read and whether Letflow adopts or diverges from
R-Co's tenant-column model; how the event-sourced tables
(`src/event_store/`) differ in migration strategy from regular CRUD
tables — event logs are typically append-only/immutable in a way
regular tables aren't, which affects both the migration shape and
what "redesign idiomatically" even means for them._

_This decision does not include writing actual migrations — that
happens under S2/S3 once this strategy is settled._
