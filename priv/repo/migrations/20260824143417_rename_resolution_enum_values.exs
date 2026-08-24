defmodule Letflow.Repo.Migrations.RenameResolutionEnumValues do
  use Ecto.Migration

  # Renames the two divergent enum values in pack_update_resolutions to match
  # R-Co's ResolutionKind enum (pack_update.zig:25-29). The write path was never
  # built (REQ-041 scope note), so no live tenant rows carry the old values.
  # REQ-147 / ISS-0096.

  def up do
    execute "UPDATE pack_update_resolutions SET resolution = 'keep_local' WHERE resolution = 'keep_theirs'"
    execute "UPDATE pack_update_resolutions SET resolution = 'merged' WHERE resolution = 'custom'"
  end

  def down do
    execute "UPDATE pack_update_resolutions SET resolution = 'keep_theirs' WHERE resolution = 'keep_local'"
    execute "UPDATE pack_update_resolutions SET resolution = 'custom' WHERE resolution = 'merged'"
  end
end
