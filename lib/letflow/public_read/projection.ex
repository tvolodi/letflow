defmodule Letflow.PublicRead.Projection do
  @moduledoc """
  The behaviour every registered `<kind>` implements (REQ-323 §4.4, extracted
  into its own file by REQ-352 design §1 since REQ-323 shipped no code, only
  the design doc -- the callback signatures below are reused verbatim from
  that design, not altered).

  `Letflow.Routers.PublicRead` (the sub-router) knows only this shape --
  adding a kind means registering a `{kind_string, projection_module}` pair
  in `:public_read_kinds` application config (see
  `Letflow.PublicRead.fetch_kind/1`) plus one new module implementing this
  behaviour, never touching the router itself.
  """

  @typedoc "The tenant-scoped row a handle points at, fetched inside the derived prefix."
  @type resource :: struct()

  @typedoc """
  The subset of the handle row a projection may see. Deliberately narrow: it
  carries `issued_at` (which the response envelope needs) and `kind`, and
  nothing a projection could leak -- no `tenant_id`, no `handle_hash`, no
  `resource_id`.
  """
  @type handle_meta :: %{issued_at: DateTime.t(), kind: String.t()}

  @doc """
  The Ecto schema module this kind's resource lives in. `Letflow.PublicRead.resolve/2`
  uses it for round-trip 2 (`Repo.get(schema(), resource_id, prefix: derived_prefix)`),
  which is why a projection module never issues a query of its own.
  """
  @callback schema() :: module()

  @doc """
  Builds the `"data"` value of the response envelope, or declines to publish.

  MUST be pure: no `Repo` call, no `Application` read, no clock read, no
  process dictionary -- a projection that queries would break the
  resolution path's fixed round-trip count, which is an INV-5 property, not
  a performance one.

  Returns `{:ok, map}` with literal string keys, hand-written in this
  function, or `:skip` when the resource is not publishable in its current
  state -- the router turns `:skip` into the standard 404, never into a
  distinguishable response.
  """
  @callback project(resource(), handle_meta()) :: {:ok, %{optional(String.t()) => term()}} | :skip
end
