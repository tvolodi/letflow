# priv/packs/bilimbaga

This directory holds authored bucket-A pack **content** for the BilimBaga
vertical (S10 P2) -- pure definitions, no Elixir application code and no
TypeScript. See `docs/migration/decisions/0022-*.md`'s bucket table:
bucket A is "pure definitions -- no Elixir, no TypeScript. Entity
definitions, process definitions, form schemas, role-registry seeds, Lua
grading rules", built by REQ-ANALYST + CODE-DESIGNER and delivered in a
solution-pack document. Nothing under `priv/packs/` may depend on or
duplicate code under `lib/letflow/` or `web/`.

## Convention: one file per entity type

`entity_definitions/` holds one JSON file per entity type, named after the
entity (`category.json`, `tag.json`, `question.json`,
`answer_option.json`, `question_tag.json`). Each file's top-level object is
exactly a `Letflow.Entities.Definition.t()` document with string keys:
`name`, `display_name`, an optional `description`, `fields`, and the
optional `indexes`, `foreign_keys` and `constraints` arrays -- no wrapper
object, no metadata envelope. JSON (not YAML) because
`Letflow.Definitions.SolutionPack`'s install path parses a string-keyed
`definition_json` object through `solution_pack.ex`'s
`atomize_definition_json/1`, so these are the same bytes the pack document
will carry once REQ-328 packages them.

A later executor adding a sixth definition to this pack should follow the
same shape: one JSON file, no wrapper object, and every `indexes` /
`foreign_keys` / `constraints` entry carrying its own `name` key following
the `<prefix>_<entity>_<columns>` convention (`idx_`/`fk_`/`uq_`).

## FR-BB citation rule

Every definition document in this pack cites its source functional
requirement id inside its own `description` field -- FR-BB21 for `category`
and `tag` (source: `008_categories_tags.up.sql`, roadmap section 2.1),
FR-BB22 for `question`, `answer_option` and `question_tag` (source:
`009_questions.up.sql`, roadmap sections 2.2/2.3). This lets a later reader
trace any field back to the port source without leaving the document.

## Deferred: parent_id on category and question

Two source columns are self-referential foreign keys that Letflow rejects
today: `categories.parent_id` (the category tree) and `questions.parent_id`
(version lineage). `Letflow.Entities.Definition.Validator`'s Rule 9
rejects any `fk_def` whose `references_entity` equals the definition's own
name. REQ-324 (pending) lifts that restriction. Both `category.json` and
`question.json` state this gap in their own `description` fields. A
follow-on requirement should add `parent_id` plus its `fk_def` to both
documents once REQ-324 lands -- do not work around the gap with an
unenforced string field, a closure table, or a JSON-nested tree in the
meantime.

## Open item: starter category records

BilimBaga's `008_categories_tags.up.sql` seeds three root categories
(Security Awareness, Workplace Safety, Loyalty and Values) with hard-coded
UUIDs. Those are records, not definitions, and are not authored here or by
REQ-327/REQ-328 -- REQ-328's install is a definition install. Whether this
pack should seed starter category records at all, and if so how, is left
open for a future requirement to decide.
