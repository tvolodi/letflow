defmodule Letflow.EventStore.JSONArray do
  @moduledoc """
  Custom `Ecto.Type` for a `jsonb` column that holds a JSON **array**, rather
  than a JSON object.

  ## Why this exists (design `req043-instance-engine-schema.md` §2.4/OQ-3,
  resolved empirically, not by design-time guess)

  Ecto's built-in `:map` type strictly requires `is_map/1` at *both* cast and
  dump time (`deps/ecto/lib/ecto/type.ex`'s `same_map/1` — used unconditionally
  for the literal `:map` type, unlike a custom type module, which routes
  through its own callbacks instead). REQ-043's design doc flagged, as OQ-3, an
  *unverified* concern that `Ecto.Changeset.cast/3` might reject a list value
  for a `:map`-typed field, and named `Ecto.Changeset.put_change/3` as the
  documented fallback if so.

  Empirically (via a real insert against Postgres while implementing this
  requirement — not assumed), the actual failure is one layer further down
  than OQ-3 anticipated: `cast/3` does accept a list, and `put_change/3` does
  too, but `Repo.insert/2`'s **dump** step (`Ecto.Repo.Schema.dump_field!/6`)
  raises `Ecto.ChangeError: value [] ... does not match type :map` regardless
  of how the list got into the changeset, because the built-in `:map` type's
  `dump/1` clause (`same_map/1`) rejects any non-map term unconditionally, and
  a schema-level `field(:current_nodes, :map, default: [])` fails even
  earlier, at compile time (`Ecto.Schema.validate_default!/3`, before any
  changeset exists at all). There is no way to make the built-in `:map` type
  hold a bare JSON array end-to-end through Ecto's cast/dump/load pipeline —
  `put_change/3` alone does not solve it, contrary to what OQ-3 assumed.

  This module is the minimal fix: a custom `Ecto.Type` whose `type/0` still
  reports `:map` (so the Postgres adapter picks the identical jsonb wire
  encoding a plain `:map` field would — the underlying `jsonb` column and its
  `'[]'::jsonb` DB-level default, both already correct, are untouched), but
  whose `cast/1`/`dump/1`/`load/1` accept a `list()` instead of requiring
  `is_map/1`. Scoped narrowly to exactly this need — not a general "any JSON
  value" type, and not reused for `variables`/`error_detail`
  (`Letflow.EventStore.InstanceProjection`'s two genuinely object-shaped jsonb
  fields), which keep the plain built-in `:map` type since they hold real
  JSON objects and hit none of this.

  Flagged for REVIEWER: this is a new type module the approved design's own
  text did not literally specify (it specified `field(:current_nodes, :map,
  default: [])`), added because implementing that literal text turned out to
  be impossible against real Ecto/Postgres, not a stylistic preference.
  """

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value) when is_list(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def load(value) when is_list(value), do: {:ok, value}
  def load(_value), do: :error

  @impl true
  def dump(value) when is_list(value), do: {:ok, value}
  def dump(_value), do: :error
end
