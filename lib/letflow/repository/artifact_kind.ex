defmodule Letflow.Repository.ArtifactKind do
  @moduledoc """
  The shared `artifact_kind` value list (REQ-203 OQ-B,
  `lib/letflow/design/req203-artifact-activation.md` §9) -- the single
  source of truth `Letflow.Repository.ArtifactVersion`,
  `Letflow.Repository.Activation`, and `Letflow.Repository.ActivationHistory`
  all declare their own `Ecto.Enum` field against, so the eight-atom value
  set can never drift between "creatable" (REQ-202) and "activatable"
  (REQ-203) artifact kinds.

  REQ-226 (ISS-0438 entity-subsystem port, slice 2) added `:entity` as this
  list's eighth value -- a one-line, non-structural addition (see
  `lib/letflow/design/req226-entity-definitions-persistence-crud.md` §2):
  nothing in this codebase pattern-matches on a specific finite set of
  `artifact_kind` atoms rather than treating the value opaquely.

  Deliberately has no compile-time dependency on `Letflow.Repository` or any
  of the schema modules that reference it -- `Letflow.Repository` itself has
  a compile-time struct dependency on `Letflow.Repository.ArtifactVersion`
  (a pattern match on `%ArtifactVersion{}` in `next_version/3`), so if this
  value list lived on `Letflow.Repository` instead, every schema module
  declaring an `Ecto.Enum` field against it at compile time would deadlock
  the compiler (`ArtifactVersion` -> `Letflow.Repository` -> `ArtifactVersion`).
  This module exists solely to break that cycle.
  """

  @artifact_kinds [
    :definition,
    :form,
    :schema,
    :service_catalog,
    :script,
    :module,
    :scenario,
    :entity
  ]

  @type t ::
          :definition
          | :form
          | :schema
          | :service_catalog
          | :script
          | :module
          | :scenario
          | :entity

  @doc "The shared eight-atom `artifact_kind` value list."
  @spec values() :: [t()]
  def values, do: @artifact_kinds
end
