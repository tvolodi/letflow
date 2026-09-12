# Relocated and dropped source constraints — BilimBaga exam configuration (REQ-327)

This file records what happened to every `CHECK` constraint in the two source
migrations this directory's exam-configuration definitions port from, and records
one entity type that was deliberately not authored at all. It exists so that a later
executor authoring the form schemas knows exactly what must be re-expressed there,
and so a reviewer can confirm nothing was silently dropped.

Sources:

- `c:\Users\tvolo\dev\ai-dala\BilimBaga\backend\migrations\012_exams.up.sql`
  (header `-- FR-BB31: Exam Configuration Model`)
- `c:\Users\tvolo\dev\ai-dala\BilimBaga\backend\migrations\013_exam_assignments.up.sql`
  (header `-- FR-BB33: Exam Assignment`)
- Product spec: `corporate_exam_platform_roadmap.md` sections 3.1 (exam configuration
  model), 3.2 (configuration API) and 3.3 (exam assignment).

## Why none of these can be expressed as an entity-definition constraint

`Letflow.Entities.Definition`'s `constraint_def` type declares
`required(:type) => :unique` — a single literal atom, not a union — and there is no
`check_def` type of any kind. The enforcing code is
`lib/letflow/entities/definition/validator.ex`'s `constraint_shape_violations/1`,
which rejects any constraint whose `type` is not `:unique`:

```elixir
Map.get(constraint, :type) != :unique ->
  [malformed([:constraints, Map.get(constraint, :name)], "constraint type must be :unique")]
```

`Letflow.Definitions.SolutionPack`'s `translate_constraint/1` narrows this further at
the pack-parsing boundary: the only string it will translate for a constraint's
`type` is `"unique"`; anything else is `{:error, :invalid_pack_document}`.

Nor is there a field-level escape hatch. `field_def` has no `min`, `max`, `range` or
`check` attribute — its optional keys are exactly `required`, `queried`, `enum_values`,
`decimal_precision`, `decimal_scale`, `default`, `locales` and `search_strategy`. A
numeric field cannot carry a bound today.

So every `CHECK` below has no storage-layer expression in Letflow, and this file
relocates it explicitly rather than dropping it silently.

## Verification that this list is complete

`grep -n CHECK` over both source migrations, output quoted verbatim:

```
=== 012_exams.up.sql ===
18:    time_limit_minutes  INT NOT NULL CHECK (time_limit_minutes > 0),
19:    passing_score_pct   DECIMAL(5, 2) NOT NULL CHECK (passing_score_pct BETWEEN 0 AND 100),
20:    max_attempts        INT NOT NULL DEFAULT 1 CHECK (max_attempts > 0),
31:    CONSTRAINT exams_availability_check CHECK (
44:    sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
61:    count       INT NOT NULL CHECK (count > 0),
62:    sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
73:    sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),

=== 013_exam_assignments.up.sql ===
14:    CONSTRAINT exam_assignments_id_required CHECK (
```

Nine `CHECK` occurrences across the two files; all nine appear in the table below.

## Group (i) — the one multi-column comparison

### `exams_availability_check`

Source: `012_exams.up.sql` lines 31–33, on table `exams`, verbatim:

```sql
    CONSTRAINT exams_availability_check CHECK (
        available_from IS NULL OR available_until IS NULL OR available_from < available_until
    )
```

- **Entity type / fields constrained:** `exam` — `available_from`, `available_until`
  (both `:datetime`, both `queried: true`, both `required: false`).
- **Why inexpressible:** it compares two columns. There is no `check_def`, and a
  two-column predicate has no field-level shape either.
- **Relocates to:** the exam's authoring form schema, as an `Expr` predicate evaluated
  by the `Expr` evaluators REQ-291 (definition-time evaluation), REQ-292 (server-side
  evaluation) and REQ-293 (the TypeScript evaluator) landed — S10 gap 7, closed.
  REQ-327 does not author the form schema; it records this relocation.
- **Enforcement after relocation:** form-layer only. See the honesty note below — it
  applies to this constraint as much as to group (ii).

## Group (ii) — single-column range checks

All seven of these are range predicates on one column. Each relocates to the same
form-schema / `Expr` layer named above (REQ-291 / REQ-292 / REQ-293).

| Source line | Verbatim | Entity type | Field |
|---|---|---|---|
| `012` :18 | `time_limit_minutes  INT NOT NULL CHECK (time_limit_minutes > 0),` | `exam` | `time_limit_minutes` |
| `012` :19 | `passing_score_pct   DECIMAL(5, 2) NOT NULL CHECK (passing_score_pct BETWEEN 0 AND 100),` | `exam` | `passing_score_pct` |
| `012` :20 | `max_attempts        INT NOT NULL DEFAULT 1 CHECK (max_attempts > 0),` | `exam` | `max_attempts` |
| `012` :44 | `sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),` | `exam_section` | `sort_order` |
| `012` :61 | `count       INT NOT NULL CHECK (count > 0),` | `exam_question_rule` | `count` |
| `012` :62 | `sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),` | `exam_question_rule` | `sort_order` |
| `012` :73 | `sort_order  INT NOT NULL DEFAULT 0 CHECK (sort_order >= 0),` | `exam_manual_question` | `sort_order` |

(Seven rows: `sort_order >= 0` appears on three separate tables and is listed once
per table, since each is a distinct constraint on a distinct entity type.)

### THIS IS A LOSS, NOT AN EQUIVALENT RELOCATION

State it plainly, because softening it would mislead whoever reads this next.

In the source system, PostgreSQL rejected a negative `time_limit_minutes`, a
`passing_score_pct` of `500`, a `count` of `0` or a negative `sort_order` at the
database level, on **every** write path, including any path that bypassed the
application. In Letflow after this port, **nothing in the storage layer will reject
any of those values.** A negative time limit written through the record API directly
is accepted and persisted. There is no entity-definition attribute that would stop it
and no DDL emitted by `lib/letflow/entities/definition/ddl.ex` that encodes a range.

Form-schema / `Expr` validation catches these only on the write paths that go through
a form. It is a weaker guarantee than the source had, and it is not defence in depth
against a direct record write. Do not read the "relocates to" column above as meaning
the constraint is preserved somewhere else — it means the requirement it expressed is
recorded somewhere else, to be re-implemented, with a gap in the meantime.

Closing that gap properly would require either a `check_def` shape in
`Letflow.Entities.Definition` or min/max attributes on `field_def`. Neither exists,
and REQ-327 does not author them — that is a platform change (bucket B), not pack
content.

## Group (iii) — `exam_assignments_id_required`, and the entity that was not authored

Source: `013_exam_assignments.up.sql` lines 14–16, on table `exam_assignments`,
verbatim:

```sql
    CONSTRAINT exam_assignments_id_required CHECK (
        assignee_type = 'all' OR assignee_id IS NOT NULL
    )
```

This is a conditional-requiredness rule across two columns — inexpressible for the
same reason as group (i), and doubly moot here, because the entity type it would
constrain is not authored at all.

### `exam_assignment` is deliberately NOT authored — OPEN QUESTION

FR-BB33, source table `exam_assignments` in
`013_exam_assignments.up.sql`, roadmap section 3.3.

The reason is substantive, not sizing. The source table's shape:

```sql
CREATE TABLE exam_assignments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exam_id         UUID NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
    assignee_type   assignee_type NOT NULL,
    assignee_id     UUID,
    deadline        TIMESTAMPTZ,
    assigned_by     UUID NOT NULL REFERENCES users(id),
    assigned_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ...
```

where `assignee_type` is `CREATE TYPE assignee_type AS ENUM ('user', 'department', 'all')`.

- `assignee_id` is a **polymorphic** reference: its target depends on `assignee_type` —
  a user id, a department id, or nothing at all when the type is `'all'`. No `fk_def`
  can express that: `references_entity` names exactly one entity type, statically.
- Two of the three targets (user, department) live in the **identity subsystem**,
  which an entity `fk_def` cannot reach at all. This is the same boundary that drops
  `created_by` from `exam.json` and, per REQ-326, from that requirement's documents.
- `assigned_by` hits the same boundary as `created_by`, with the same answer: the
  event stream's `actor_id`.

**This is recorded as an open question and is NOT settled here.** REQ-327 may not pick
a shape for it. The candidate shapes noted, without preference:

1. An entity type with an unenforced string reference for `assignee_id`, plus the
   conditional-requiredness rule relocated to the form layer (inheriting the same loss
   documented in group (ii) above).
2. A process-definition concern. Decision `0022`'s reasoning section 1 maps the exam
   lifecycle "assign → notify → take → grade → certify → expire" to a process
   definition on `Letflow.Engine` (bucket A), which would make assignment a process
   instance rather than an entity record.
3. Something else.

Resolution belongs to a later decision-record requirement or to the
process-definition requirement that follows in S10 P2.

## Not a constraint, but recorded here for completeness: `tag_ids`

`012_exams.up.sql` line 59 declares `tag_ids JSONB NOT NULL DEFAULT '[]'::jsonb` on
`exam_question_rules`. That column is not ported as a field; it is remodelled as the
`exam_question_rule_tag` join entity in this directory, per
`docs/anti-patterns.md`'s "Modelling many-to-many as an array of references on the
parent record" entry. The `NOT NULL DEFAULT '[]'` behaviour has no analogue in the
join shape and needs none — the absence of join rows *is* the empty set.
