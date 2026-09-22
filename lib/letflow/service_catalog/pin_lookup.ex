defmodule Letflow.ServiceCatalog.PinLookup do
  @moduledoc """
  REQ-373 (design `lib/letflow/design/req373-service-catalog-version-lifecycle.md`
  §5) -- the first REAL (non-`default_lookup/0`) `Letflow.Engine.PinResolver.Lookup`
  implementation. Wired into `Letflow.Engine.create/2`'s `pin_lookup/2` helper
  (§6) in place of `PinResolver.default_lookup/0`.

  **`catalog_entry` resolution only.** `module_lookup` stays a permanent
  `{:error, :not_found}` stub -- PLC-01 (the process module catalog) does
  not exist in this codebase and is unscoped to any stage, exactly the gap
  `Letflow.Engine.PinResolver`'s own moduledoc names under its "SCOPE GAP —
  service_catalog (S6) and PLC-01 (unscoped) are not built" section. This
  module closes the `service_catalog` half of that gap only; the PLC-01 half
  remains open, not silently expanded into this requirement's scope.

  Not folded into `Letflow.ServiceCatalog` itself (unlike
  `scope_validator_lookup/1`) because `build/0`'s shape needs to compose
  with `PinResolver.default_lookup/0`'s own `variable_schema_lookup` rather
  than reimplement it -- see `build/0` below.
  """

  alias Letflow.Engine.PinResolver
  alias Letflow.Repo
  alias Letflow.ServiceCatalog.Entry

  @doc """
  Constructs a `PinResolver.Lookup.t()` whose `module_lookup`/
  `variable_schema_lookup` fields are copied verbatim from
  `PinResolver.default_lookup/0`'s own result (guaranteeing byte-identical
  behavior for both, with zero risk of drift between the two
  implementations) and whose `catalog_lookup` field is this module's own
  `catalog_lookup/1`. Performs no `Repo` call itself -- only constructs
  closures; all I/O happens when `PinResolver.resolve/4` later invokes one.
  """
  @spec build() :: PinResolver.Lookup.t()
  def build do
    %{PinResolver.default_lookup() | catalog_lookup: &catalog_lookup/1}
  end

  @doc """
  Resolves a `SERVICE_TASK` node's `service_id` attribute against the
  versioned `service_catalog` table.

    * no row at all -> `{:error, :not_found}` (identical to
      `default_lookup/0`'s permanent stub answer -- a definition referencing
      a `service_id` nobody ever registered behaves exactly as before this
      module existed).
    * row with `status: :ACTIVE` -> `{:ok, %{resolved_id: version_id,
      version: version}}`.
    * row with `status: :RETIRED` -> `{:error, :not_found}` -- the design's
      explicit AC4 "retire fails outright" decision
      (`Letflow.ServiceCatalog.retire/1`'s own `@doc`), implemented at the
      one place `PinResolver.resolve/4` actually calls into.
  """
  @spec catalog_lookup(service_id :: String.t()) ::
          {:ok, %{resolved_id: String.t(), version: String.t()}} | {:error, :not_found}
  def catalog_lookup(service_id) when is_binary(service_id) do
    case Repo.get(Entry, service_id) do
      nil ->
        {:error, :not_found}

      %Entry{status: :ACTIVE, version_id: version_id, version: version} ->
        {:ok, %{resolved_id: version_id, version: version}}

      %Entry{status: :RETIRED} ->
        {:error, :not_found}
    end
  end
end
