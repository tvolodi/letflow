defmodule Letflow.EventStore.Registry.ValidationFailure do
  @moduledoc """
  Plain struct (not `Ecto.Schema` — never persisted) carrying one JSON Schema
  validation violation. `Letflow.EventStore.Registry.validate_payload/3`
  returns a list of these alongside its error tuple rather than exposing a
  `last_validation_failures/1`-style stateful accessor — see that module's
  moduledoc and `lib/letflow/design/req024-event-type-registry.md` section
  4.2/4.5 for why: Elixir's tagged-tuple return has room to carry the
  failures with the error itself, so there is no "valid until next call"
  hazard the way R-Co's shared-mutable-field `Registry.last_failures` has in
  Zig.

  `field_path` is always an RFC 6901 JSON Pointer (`"/"` for the document
  root, `"/foo/0/bar"` for nested/indexed locations). `constraint` is always
  one of the keyword-name string literals
  `Letflow.EventStore.Registry.JsonSchema` emits (`"type"`, `"enum"`,
  `"minimum"`, `"maximum"`, `"minLength"`, `"maxLength"`, `"required"`,
  `"additionalProperties"`) — never a free-form message string, so a caller
  can assert on the literal constraint name rather than parse a sentence.
  `actual` is kept as the raw, already-decoded Elixir term (not serialized to
  a string, unlike R-Co's allocator-owned `[]const u8` field) — see the
  design doc section 4.4's "actual value convention" note.
  """

  @type t :: %__MODULE__{
          field_path: String.t(),
          constraint: String.t(),
          actual: term()
        }

  defstruct [:field_path, :constraint, :actual]
end
