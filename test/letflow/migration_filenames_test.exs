defmodule Letflow.MigrationFilenamesTest do
  @moduledoc """
  ISS-0061 regression: guards against a second occurrence of the duplicate-migration-
  version collision class documented in `docs/anti-patterns.md` ("A rebase add/add
  conflict on docs/issues/ISS-NNNN.yaml can land without git ever flagging it as
  CONFLICT" and the sibling module-name-collision entries) -- this is the same
  cross-host filename/id collision shape, but against an Ecto migration version number
  instead of a module name or a `docs/issues/` entry.

  Two independently-merged migration files
  (`20260819000001_create_groups_tenant_scoped.exs` from REQ-063 and
  `20260819000001_drop_transition_events.exs` from REQ-046/#199) landed on `main` with
  the identical leading version prefix `20260819000001`. Ecto's own duplicate-version
  guard in `Ecto.Migrator` caught it, but only at `mix ecto.migrate`/`mix test` run
  time -- `Ecto.MigrationError: migration version 20260819000001 is duplicated` --
  which blocks every host working the backlog, not just the one that finds it first.
  See `docs/issues/ISS-0061.yaml`.

  This is a pure filesystem/string check -- no database, no `Letflow.DataCase` --
  matching `docs/guides/test_developer_guide.md` "Pure functions first": a version
  collision is a static property of the files on disk, not of anything requiring
  Postgres to observe.
  """

  use ExUnit.Case, async: true

  @migrations_dir Path.join([File.cwd!(), "priv", "repo", "migrations"])

  describe "priv/repo/migrations/ version prefixes" do
    test "no two migration files share the same leading version number" do
      files =
        @migrations_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.sort()

      assert files != [], "expected to find migration files under #{@migrations_dir}"

      files_by_version =
        Enum.group_by(files, fn filename ->
          [version | _rest] = String.split(filename, "_", parts: 2)
          version
        end)

      duplicates =
        files_by_version
        |> Enum.filter(fn {_version, group} -> length(group) > 1 end)
        |> Enum.sort_by(fn {version, _group} -> version end)

      assert duplicates == [],
             "duplicate migration version number(s) found under #{@migrations_dir} " <>
               "(ISS-0061 regression class -- rename one side to a unique, still-" <>
               "chronologically-later version):\n" <>
               Enum.map_join(duplicates, "\n", fn {version, group} ->
                 "  version #{version} used by: #{Enum.join(group, ", ")}"
               end)
    end

    test "every migration filename starts with a purely numeric version prefix" do
      files =
        @migrations_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.sort()

      non_numeric =
        Enum.reject(files, fn filename ->
          case String.split(filename, "_", parts: 2) do
            [version, _rest] -> version != "" and String.match?(version, ~r/^\d+$/)
            _ -> false
          end
        end)

      assert non_numeric == [],
             "migration filename(s) with a non-numeric or missing version prefix: " <>
               Enum.join(non_numeric, ", ")
    end
  end
end
