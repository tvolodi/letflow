defmodule Letflow.Entities.Definition.Shape do
  @moduledoc """
  Canonicalisation, content hashing, and logical-shape versioning for a
  `Letflow.Entities.Definition.t()` document (REQ-225). See
  `lib/letflow/design/req225-entity-definition-schema-validation.md` §§4-5
  for the full design this module implements.

  ## Reuses `Letflow.Repository.Canonicaliser` -- no second canonicaliser

  This module performs **no canonicalisation or hashing of its own**. Both
  `content_hash/1` and `logical_shape_of/1` encode a document to JSON via
  `Jason.encode!/1` and then delegate to the existing
  `Letflow.Repository.Canonicaliser` (REQ-202,
  `lib/letflow/repository/canonicaliser.ex`) for both the canonical-form
  computation (`canonicalize_content/2`) and the SHA-256 digest
  (`content_hash/1`). This module never re-implements key-sorting,
  number-normalisation, or hashing -- an entity definition is JSON content
  destined for the artifact store the same way a form or script definition
  is, so it must canonicalise identically.

  Callers are expected to have already called
  `Letflow.Entities.Definition.Validator.validate/1` and received `:ok` --
  neither function here validates.
  """

  alias Letflow.Entities.Definition
  alias Letflow.Repository.Canonicaliser

  @typedoc "Raw 32-byte SHA-256 digest, matching `Letflow.Repository.Canonicaliser.content_hash/1`'s own return type."
  @type content_hash :: binary()

  @typedoc "Raw 32-byte SHA-256 digest of the order/display-stripped logical-shape probe document."
  @type logical_shape_digest :: binary()

  @non_logical_fields [:display_name, :description]
  @orderable_lists [:fields, :indexes, :foreign_keys, :constraints]

  @doc """
  Encodes `definition` to JSON and delegates to
  `Letflow.Repository.Canonicaliser.canonicalize_content/2` +
  `Letflow.Repository.Canonicaliser.content_hash/1`.
  """
  @spec content_hash(definition :: Definition.t()) :: content_hash()
  def content_hash(definition) do
    hash_via_canonicaliser(definition)
  end

  @doc """
  Computes the logical-shape digest: strips `display_name`/`description`,
  sorts `fields`/`indexes`/`foreign_keys`/`constraints` by each entry's
  `name`, then canonicalises and hashes the resulting probe document via the
  same `Letflow.Repository.Canonicaliser` calls `content_hash/1` uses.

  Two documents produce the same digest if and only if they have the same
  logical shape per the rule stated in the design's §5: non-logical changes
  (field/index/FK/constraint reordering, `display_name`/`description`
  changes) do not change the digest; any other change does.
  """
  @spec logical_shape_of(definition :: Definition.t()) :: logical_shape_digest()
  def logical_shape_of(definition) do
    definition
    |> Map.drop(@non_logical_fields)
    |> sort_orderable_lists()
    |> hash_via_canonicaliser()
  end

  defp sort_orderable_lists(definition) do
    Enum.reduce(@orderable_lists, definition, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        list when is_list(list) -> Map.put(acc, key, Enum.sort_by(list, &Map.get(&1, :name)))
      end
    end)
  end

  defp hash_via_canonicaliser(document) do
    json_bytes = Jason.encode!(document)
    {:ok, canonical_form} = Canonicaliser.canonicalize_content("application/json", json_bytes)
    Canonicaliser.content_hash(canonical_form)
  end
end
