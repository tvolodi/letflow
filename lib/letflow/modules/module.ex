defmodule Letflow.Modules.Module do
  @moduledoc """
  The module contract (REQ-400, `docs/migration/decisions/0039-platform-module-solution-layering.md`
  D4; design `lib/letflow/design/req400-module-behaviour-catalog.md` §1).

  ## File placement (D3)

  This file is **core** code, not a module — it lives at
  `lib/letflow/modules/module.ex`, one level, no subdirectory. It is the
  behaviour a module's own entry file (`lib/letflow/modules/<id>/<id>.ex`)
  implements; it is not itself an example of the file-level core/module split
  D3 draws. Only `Letflow.Modules.Catalog` is core code permitted to
  reference a specific module's entry file by name (D3's xref limitation) —
  this file must never be edited to name a concrete module.

  ## Contract summary (D4)

  * `manifest/0` — **required**. Every entry module must implement it; a
    module with no `manifest/0` is not a valid entry module. Returns the
    exact map shape `t:manifest/0` below.
  * `router/0` — **optional**. Returns the `Plug.Router`-implementing module
    itself (a `module()`, not a started process) that the platform mounts
    under `/api/v1/modules/<id>/…`. REQ-400 defines only the shape; mounting
    it is REQ-403's job.
  * `on_install/2` — **optional**. Receives `prefix` (the tenant's schema
    prefix, threaded the same way every other tenant-scoped call in this
    codebase threads it, per `docs/agents/instructions/security-invariants.md`
    INV-1) and `settings` (the module's settings map at install time).
    Returns `:ok` or `{:error, term()}`. Runs inside the install transaction
    after the module's pack is installed (D4) — REQ-400 defines only the
    callback's own contract, not the transaction that calls it (REQ-402).

  `router/0` and `on_install/2` are declared `@optional_callbacks` — Elixir's
  `@callback`/`@optional_callbacks` machinery auto-generates
  `behaviour_info/1`, so no separate introspection function is written here.
  """

  @typedoc """
  One entry of a manifest's `route_policies` list: an HTTP method (upper-case
  string, e.g. `"GET"`), a path pattern relative to the module's own mount
  `/api/v1/modules/<id>` (does not repeat that prefix), and the permission
  atom required to reach it.
  """
  @type route_policy :: {method :: String.t(), path_pattern :: String.t(), permission :: atom()}

  @typedoc """
  The manifest map shape every entry module's `manifest/0` must return
  (design §1.3). Field semantics:

    * `:id` — the module's own id string (e.g. `"fixture"`, `"exam"`).
    * `:version` — a version string, opaque to this requirement.
    * `:depends_on` — other module ids this module requires installed first.
    * `:pack` — a path to the module's solution-pack document, or `nil`.
    * `:permissions` — the permission atoms this module declares and owns.
    * `:role_grants` — `%{role_atom => [permission_atom]}`, restricted to
      atoms this module itself declares in `:permissions` and to role atoms
      already known to `Letflow.Api.Authorization.roles/0`.
    * `:required_roles` — advisory only (0029 §2); stored, not enforced.
    * `:settings_schema` — a JSON-Schema-shaped map describing the module's
      configurable settings, or `nil` if it has none.
    * `:route_policies` — see `t:route_policy/0`.
  """
  @type manifest :: %{
          required(:id) => String.t(),
          required(:version) => String.t(),
          required(:depends_on) => [String.t()],
          required(:pack) => String.t() | nil,
          required(:permissions) => [atom()],
          required(:role_grants) => %{atom() => [atom()]},
          required(:required_roles) => [String.t()],
          required(:settings_schema) => map() | nil,
          required(:route_policies) => [route_policy()]
        }

  @callback manifest() :: manifest()
  @callback router() :: module()
  @callback on_install(prefix :: String.t(), settings :: map()) :: :ok | {:error, term()}

  @optional_callbacks router: 0, on_install: 2
end
