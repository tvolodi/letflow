/** BPM Platform — shared TypeScript types mirroring backend response shapes */

// ── API infrastructure ─────────────────────────────────────────────────────────

/** RFC 9457 Problem Details error shape */
export interface ApiError {
  status: number
  message: string
  code: string
  details?: Record<string, unknown>
}

/**
 * Cursor-paginated list response (API-13) — the **two-key** envelope, exactly
 * `{items, next_cursor}` and nothing else.
 *
 * Routes that emit this shape (ISS-0816 design §2.2, each re-read from its own
 * response builder):
 *   - `GET /api/v1/definitions`        (`lib/letflow/routers/definitions.ex:454-458`)
 *   - `GET /api/v1/definitions/search` (`lib/letflow/routers/definitions.ex:539-544`)
 *   - `GET /api/v1/dlq`                (`lib/letflow/routers/dlq.ex:140-144`)
 *   - `GET /api/v1/services`           (`lib/letflow/routers/services.ex:131-135`)
 *   - `GET /api/v1/admin/services`     (`lib/letflow/routers/admin_services.ex:198-202`)
 *   - `GET /api/v1/promotions`         (`lib/letflow/routers/promotions.ex:944-948`)
 *   - `POST /api/v1/entities/query`    (`run_query/4`; aliased below as `EntityRecordsPage`)
 *
 * ISS-0816: **no Letflow route emits `has_more` on the wire — not one.** The
 * field used to be declared here and covered zero wire shapes. The only place a
 * `has_more` exists at all is *inside* Elixir: `Letflow.Audit.list_entries/1`
 * returns one, and `lib/letflow/routers/audit.ex:308-320` (`page_body/2`) drops
 * it, converting it into a cursor and hand-building an INV-2 allowlist of
 * `"items"`, `"next_cursor"` and `"count"`. Next-page availability is derived
 * from `next_cursor !== null` at the point of use (INV-C); no API-layer function
 * may return a pre-derived boolean for it. Do not re-file this.
 */
export interface CursorPage<T> {
  items: T[]
  next_cursor: string | null
}

/**
 * The **three-key** envelope, exactly `{items, next_cursor, count}`.
 *
 * Routes that emit this shape (ISS-0816 design §2.2):
 *   - `GET /api/v1/audit`     (hand-built, `lib/letflow/routers/audit.ex:308-320`)
 *   - `GET /api/v1/instances` (hand-built, `lib/letflow/routers/instances.ex:954-959`)
 *   - `GET /api/v1/tasks`     (hand-built, `lib/letflow/routers/tasks.ex:269-275`)
 *   - `GET /api/v1/tasks/inbox` (same builder)
 *   - `GET /api/v1/tenants`, `GET /api/v1/identity/users`,
 *     `GET /api/v1/identity/groups/:id/members` — all via
 *     `Pagination.page_response/2` and `Letflow.Api.Pagination.Page`'s
 *     `@derive {Jason.Encoder, only: [:items, :next_cursor, :count]}`
 *     (`lib/letflow/api/pagination.ex:81`).
 *
 * INV-B: `count` is `length(items)` **for the current page only, never a
 * cross-page total**, and must never be rendered as one — rendering it as a
 * total is exactly what ISS-0711 was. Like `CursorPage<T>`, this envelope
 * carries no `has_more` field; see that type's note for why.
 */
export interface CountedCursorPage<T> {
  items: T[]
  next_cursor: string | null
  count: number
}

/** Offset-paginated list response for admin endpoints */
export interface PagedResponse<T> {
  items: T[]
  total: number
  page: number
  page_size: number
}

// ── Process Definitions (Stage 2) ─────────────────────────────────────────────

export type DefinitionStatus = 'DRAFT' | 'ACTIVE' | 'DEPRECATED' | 'ARCHIVED'
export type NodeType = 'START' | 'END' | 'HUMAN_TASK' | 'EXCLUSIVE_GATEWAY' | 'PARALLEL_GATEWAY' | 'SERVICE_TASK' | 'TIMER' | 'SUB_PROCESS'

export interface GraphNode {
  id: string
  node_type: NodeType
  label: string | null
  attributes: string | null
}

export interface GraphEdge {
  id: string
  source: string
  target: string
  condition?: string    // CEL expression for EXCLUSIVE_GATEWAY outgoing edges
  is_default?: boolean
}

export interface DefinitionGraph {
  nodes: GraphNode[]
  edges: GraphEdge[]
}

// ── SUB_PROCESS interface contract (SPC-01 / SPC-02) ────────────────────────

/** One declared input or output of a SUB_PROCESS `interface` (SPC-01). */
export interface SubProcessInterfaceEntry {
  /** Variable key. Non-empty, unique within its direction. */
  name: string
  /** Well-formed JSON Schema object (SPC-02). Constraints applied at runtime. */
  json_schema: Record<string, unknown>
  /** Absent `required` is treated as `false` (PLC-03 OQ-3). */
  required?: boolean
}

/** Optional `interface` attribute on a SUB_PROCESS node (SPC-01/SPC-02). */
export interface SubProcessInterface {
  inputs: SubProcessInterfaceEntry[]
  outputs: SubProcessInterfaceEntry[]
}

export interface ProcessDefinition {
  id: string
  name: string
  version: string
  description?: string
  status: DefinitionStatus
  graph: DefinitionGraph
  created_by: string
  created_at: string
  updated_at: string
}

export interface CreateDefinitionRequest {
  name: string
  version: string
  description?: string
  graph?: DefinitionGraph
  stage?: string | null
}

// ── Process Instances (Stage 3) ───────────────────────────────────────────────

export type InstanceStatus = 'ACTIVE' | 'COMPLETED' | 'CANCELLED' | 'ERROR'

export interface Token {
  token_id: string
  node_id: string
  status: 'active' | 'completed' | 'pending' | 'error'
  created_at: string
  event_id?: string
}

export interface ProcessInstance {
  instance_id: string
  definition_id: string
  definition_name: string
  definition_version: string
  correlation_key?: string
  status: InstanceStatus
  current_nodes: string[]
  current_tokens?: Token[]
  active_tokens?: Token[]
  updated_at?: string
  current_tasks?: Task[]
  definition_snapshot?: DefinitionGraph
  variables: Record<string, unknown>
  error_detail?: Record<string, unknown>
  started_at: string
  completed_at?: string
  cancelled_at?: string
}

export interface StartInstanceRequest {
  definition_id?: string
  definition_name?: string
  definition_version?: string
  correlation_key?: string
  initial_variables?: Record<string, unknown>
}

// ── Tasks (Stage 3) ───────────────────────────────────────────────────────────

export type TaskStatus = 'PENDING' | 'COMPLETED' | 'CANCELLED' | 'ESCALATED'

export interface Task {
  id: string
  instance_id: string
  token_id: string
  node_id: string
  node_name: string
  definition_name?: string
  definition_id?: string
  definition_version?: string
  correlation_key?: string
  status: TaskStatus
  assignee_type?: string
  assignee_ref?: string
  assignee_name?: string
  form_schema?: Record<string, unknown>
  output_variables?: Record<string, unknown>
  completed_by?: string
  completed_at?: string
  created_at: string
  updated_at?: string
  escalation_time?: string
}

export interface CompleteTaskRequest {
  output_variables?: Record<string, unknown>
}

// ── Events (Stage 1) ──────────────────────────────────────────────────────────

export interface EventRecord {
  event_id: string
  instance_id: string
  event_type: string
  payload: Record<string, unknown>
  actor_id: string
  sequence_number: number
  global_seq: number
  idempotency_key: string
  metadata: Record<string, string>
  created_at: string
}

export interface TimelineEntry {
  event_type: string
  timestamp: string
  actor_display_name: string
  description: string
  instance_id: string
  event_id: string
  sequence_num: number
  task_id: string | null
  node_id: string | null
  metadata: Record<string, unknown>
}

export interface TimelinePage {
  items: TimelineEntry[]
  next_cursor: string | null
  count: number
}

export interface AppendEventRequest {
  instance_id: string
  event_type: string
  payload: Record<string, unknown>
  actor_id: string
  idempotency_key: string
  metadata?: Record<string, string>
}

// ── Attachments (S8, REQ-212/386/387) ──────────────────────────────────────────
//
// Field names/casing match the shipped JSON verbatim (`attachment_json/1` and the
// `POST .../link` response body — lib/letflow/design/req387-attachment-document-viewer.md
// §0/§2.1) — no camelCase translation layer.

export interface Attachment {
  id: string
  instance_id: string
  file_name: string
  content_type: string
  byte_size: number
  uploaded_by: string
  description: string | null
  created_at: string
}

export interface AttachmentsPage {
  items: Attachment[]
  next_cursor: string | null
}

/** `GET /api/v1/instances/storage-usage` response — REQ-392 §1.2/§5.1. A
 *  tenant-wide (not per-instance) figure, matching `attachment_json/1`'s own
 *  field-naming convention (no camelCase translation layer). */
export interface StorageUsage {
  used_bytes: number
  allowance_bytes: number
}

// ── Dependency-version/provenance (REQ-399, PinResolver.effective_pin()) ───────

/** Mirrors `Letflow.Engine.PinResolver.source()` — exactly four values, no
 *  fifth. Kept as a string union (not a TS enum), matching this codebase's
 *  existing convention for backend-atom-as-string wire fields. */
export type EffectivePinSource = 'resolved' | 'override' | 'inherited' | 'rebound'

/** Mirrors `Letflow.Engine.PinResolver.kind()`. */
export type EffectivePinKind = 'catalog_entry' | 'variable_schema' | 'module'

/** Mirrors `pin_map/1`'s response projection
 *  (`lib/letflow/routers/instances.ex`) field-for-field — no adapter needed. */
export interface EffectivePin {
  kind: EffectivePinKind
  ref: string
  resolved_id: string | null
  version: string
  source: EffectivePinSource
}

export interface InstancePinsResponse {
  instance_id: string
  pins: EffectivePin[]
}

export interface AttachmentLink {
  attachment_id: string
  token: string
  url: string
  expires_at: string // ISO8601
  expires_in_seconds: number
}

/** Result of a successful attachment-bytes fetch — never persisted, only ever
 *  held in page-local state for the lifetime of one viewer-page mount. */
export interface AttachmentBlob {
  blob: Blob
  contentType: string
}

// ── Entities (S10 P4, REQ-336) ─────────────────────────────────────────────────
//
// Mirrors lib/letflow/entities/definition.ex's `field_def()`/`t()` document
// shape and lib/letflow/routers/entities.ex's response maps (`definition_map/1`,
// `record_map/1`, `entity_row_map/1`) exactly -- these are wire shapes, not
// aspirational ones. There is deliberately no "list"/"get by id" response type:
// the router exposes neither route (see entities.ts's own moduledoc-mirroring
// comment).

/** The closed field-type vocabulary `Letflow.Entities.Definition.field_type()`
 *  declares. Kept as a plain string union (not re-derived from TaskFormField's
 *  own type union) because the two vocabularies are different documents that
 *  happen to overlap -- entityFieldToFormField() is the explicit bridge. */
export type EntityFieldType =
  | 'string'
  | 'integer'
  | 'decimal'
  | 'boolean'
  | 'date'
  | 'datetime'
  | 'enum'
  | 'json'
  | 'localized_text'

export interface EntityFieldDef {
  name: string
  type: EntityFieldType
  required?: boolean
  queried?: boolean
  enum_values?: string[]
  decimal_precision?: number
  decimal_scale?: number
  default?: unknown
  locales?: string[]
  search_strategy?: 'plain' | 'fulltext'
}

export interface EntityIndexDef {
  name: string
  fields: string[]
  unique?: boolean
}

export interface EntityFkDef {
  name: string
  field: string
  references_entity: string
  references_field?: string
}

export interface EntityConstraintDef {
  name: string
  type: 'unique'
  fields: string[]
}

/** The raw `entity_definition()` document -- `definition_map/1`'s `"definition"` key. */
export interface EntityDefinitionDocument {
  name: string
  display_name: string
  description?: string
  fields: EntityFieldDef[]
  indexes?: EntityIndexDef[]
  foreign_keys?: EntityFkDef[]
  constraints?: EntityConstraintDef[]
}

/** `GET /entities/definitions/active/:name`'s response body (`definition_map/1`). */
export interface EntityDefinition {
  id: string
  name: string
  display_name: string
  definition: EntityDefinitionDocument
  content_hash: string
  logical_shape_version: string
  artifact_version_id: string
  status: string
  inserted_at: string
}

/** One record as returned by `POST /entities/query` (`entity_row_map/1`) or by
 *  create/update/delete (`record_map/1`). The two shapes differ only in
 *  whether `entity_type` is present (record_map includes it, entity_row_map
 *  does not, since the query request already names the type) -- both keep
 *  `record_id`/`field_values`/`deleted`/`entity_def_version`/
 *  `last_event_global_seq`, so this one interface covers both call sites. */
export interface EntityRecord {
  record_id: string
  entity_type?: string
  field_values: Record<string, unknown>
  deleted: boolean
  entity_def_version: string
  last_event_global_seq: number
}

/** `POST /entities/query`'s response body. `run_query/4` sends exactly
 *  `{"items", "next_cursor"}`, which is the two-key envelope `CursorPage<T>`
 *  now models precisely, so this is an alias rather than a hand-rolled twin
 *  (ISS-0816 decision (e)). The exported name and its `EntityRecord` default
 *  type argument are retained, so no call site changes. */
export type EntityRecordsPage<T = EntityRecord> = CursorPage<T>

export interface EntityQueryFilterClause {
  field: string
  op: 'eq' | 'ne' | 'lt' | 'lte' | 'gt' | 'gte' | 'in' | 'not_in' | 'contains' | 'is_null' | 'is_not_null'
  value?: unknown
}

export interface EntityQuerySortClause {
  field: string
  dir: 'asc' | 'desc'
}

/** `POST /entities/query`'s request body. `join` is deliberately omitted --
 *  this pilot (REQ-336) queries the `tag` entity type only, which has no
 *  foreign keys; join support is a later requirement's concern. */
export interface EntityQueryRequest {
  entity_type: string
  filters?: EntityQueryFilterClause[]
  sort?: EntityQuerySortClause[]
  cursor?: string
  page_size?: number
}

// ── Identity (Stage 4/5) ──────────────────────────────────────────────────────

// ── Auth (Stage F1) ───────────────────────────────────────────────────────────

export interface JwtPayload {
  sub: string
  display_name?: string
  name?: string
  preferred_username?: string
  roles: string[]
  exp?: number
  iat?: number
  iss?: string
  tenant_id?: string
}

export interface UserSession {
  token: string
  display_name: string
  roles: string[]
  loginSource: 'oidc' | null
  tenant_slug: string | null
  tenant_display_name: string | null
  tenant_id: string | null
  tenant_type: 'production' | 'test' | null
  production_tenant_display_name: string | null
}

export interface User {
  id?: string
  user_id?: string
  username?: string
  email: string
  display_name: string
  status?: 'ACTIVE' | 'INACTIVE'
  is_active?: boolean
  roles: string[]
  role_ids?: string[]
  group_ids?: string[]
  last_login_at?: string
  created_at: string
}

export interface Group {
  group_id?: string
  id: string
  name: string
  display_name: string
  description?: string
  is_system: boolean
  member_count?: number
}

/**
 * A single member of a group, exactly as `user_map/1`
 * (`lib/letflow/routers/identity.ex:729-740`) emits it on
 * `GET /api/v1/identity/groups/:id/members`. Deliberately NOT `User`: `User` declares
 * `roles` and `created_at` as required and `user_map/1` emits neither. The `status` and
 * `auth_source` unions are lowercase because `user_map/1` emits
 * `Atom.to_string(...)` over `Ecto.Enum` values and the router applies no upcasing.
 */
export interface GroupMember {
  id: string
  username: string
  display_name: string
  email: string
  status: 'active' | 'inactive'
  auth_source: 'internal' | 'oidc'
  inserted_at: string
  updated_at: string
}

/**
 * `Letflow.Api.Pagination.Page`'s encoder shape (`lib/letflow/api/pagination.ex:81`,
 * `@derive {Jason.Encoder, only: [:items, :next_cursor, :count]}`) — i.e. the
 * three-key envelope `CountedCursorPage<T>` models. ISS-0765 hand-rolled this
 * declaration; ISS-0816 collapses it to an alias, keeping the exported name so
 * every call site is untouched.
 */
export type GroupMemberPage = CountedCursorPage<GroupMember>

/**
 * `handle_list_groups/2`'s wire body (`lib/letflow/routers/identity.ex:468-472`):
 * items + total, with no `page` or `page_size`. Not `PagedResponse<Group>`, which
 * declares both as required.
 */
export interface GroupListResponse {
  items: Group[]
  total: number
}

/**
 * `member_result_map/3`'s wire body (`lib/letflow/routers/identity.ex:829-831`) returned
 * by `POST /api/v1/identity/groups/:id/members`.
 */
export interface GroupMemberAddResult {
  group_id: string
  user_id: string
  created: boolean
}

export interface Role {
  id: string
  name: string
  description?: string
  is_system: boolean
  permissions: RolePermission[]
}

export interface RolePermission {
  id: string
  resource: string
  action: string
}

export interface ApiToken {
  id?: string
  token_id?: string
  user_id?: string
  user_display_name?: string
  name?: string
  roles?: string[]
  last_used_at?: string
  expires_at?: string
  revoked_at?: string
  status?: 'ACTIVE' | 'REVOKED' | 'EXPIRED'
  created_at: string
}

export interface IssuedToken {
  token_id: string
  token_value: string
  user_id: string
  roles: string[]
  expires_at?: string | null
  created_at: string
}

// ── DLQ (Stage 3) ─────────────────────────────────────────────────────────────

export type DlqStatus = 'pending' | 'retrying' | 'resolved' | 'discarded'

export interface DlqRetryAttempt {
  attempt_no: number
  attempted_at: string
  outcome: 'success' | 'failed'
  error_message?: string
}

export interface DlqEntry {
  id: string
  entry_type?: string
  item_type?: string
  instance_id?: string
  reference_id?: string
  reason?: string
  full_reason?: string
  error_detail?: Record<string, unknown>
  error_chain?: unknown[]
  original_payload?: Record<string, unknown>
  source_payload?: Record<string, unknown>
  context_json?: Record<string, unknown>
  processor_metadata?: Record<string, unknown>
  retry_history?: DlqRetryAttempt[]
  retry_count: number
  max_retries?: number
  retry_limit?: number
  next_retry_at?: string
  status?: DlqStatus
  created_at: string
  first_failed_at?: string
  last_failed_at?: string
}

// ── Webhooks (Stage 5) ────────────────────────────────────────────────────────

export interface WebhookSubscription {
  id: string
  subscription_id?: string
  target_url?: string
  url?: string
  description?: string
  event_types?: string[]
  status?: 'ACTIVE' | 'PAUSED'
  is_active?: boolean
  consecutive_failures?: number
  max_attempts?: number
  last_attempt_at?: string | null
  last_failure_at?: string | null
  paused_at?: string | null
  hmac_secret_once?: string
  created_at: string
  updated_at?: string
}

export type WebhookDeliveryAttemptStatus = 'SUCCESS' | 'FAILED'

export interface WebhookDeliveryAttempt {
  delivery_id: string
  subscription_id: string
  event_type: string
  status: WebhookDeliveryAttemptStatus
  http_status_code: number | null
  attempted_at: string
  attempt_count: number
  max_attempts: number
  last_error?: string | null
}

export interface WebhookDeliveryAttemptListResponse {
  items: WebhookDeliveryAttempt[]
}

// ── Audit Log ─────────────────────────────────────────────────────────────────

export interface AuditEntry {
  id: string
  actor_id?: string
  actor_email?: string
  action: string
  entity_type?: string
  entity_id?: string
  entity_name?: string
  ip_address?: string
  trace_id?: string
  detail?: Record<string, unknown>
  occurred_at: string
}

// ── Health ────────────────────────────────────────────────────────────────────

export interface ComponentStatus {
  status: string
  latency_ms?: number
}

export interface HealthStatus {
  status: 'ok' | 'degraded' | 'down'
  db_latency_ms: number
  uptime_seconds: number
  version: string
  components: Record<string, ComponentStatus>
}
