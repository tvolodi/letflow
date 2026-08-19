defmodule Letflow.TenantSlugFixtureTest do
  @moduledoc """
  Regression test for ISS-0059 ("Flaky slug collision in migrations_test.exs's
  insert_tenant!/0 (:auto sandbox, real commits)") — proves both halves of the
  fix:

  1. The PRE-FIX mechanism (`"<prefix>-\#{System.unique_integer([:positive,
     :monotonic])}"`) really does collide across two independent BEAM VM
     runs — not a hypothetical, mechanically demonstrated below by spawning
     genuinely separate OS processes, each a fresh VM, and showing their
     first `unique_integer/1` call returns the identical value every time.
     This is precisely ISS-0059's failure mode: a prior `mix test` invocation
     crashes before its `on_exit` cleanup runs (leaving a `tenants` row with
     slug `"req027-1"` committed for real, since these modules run
     `Sandbox.mode(Letflow.Repo, :auto)`), and the next `mix test` VM's
     counter restarts from 1, generating the identical slug and colliding
     against the real `tenants_slug_index` unique constraint.

  2. The POST-FIX mechanism (`Letflow.TenantSlugFixture.unique_slug/1`, an
     `Ecto.UUID.generate/0`-derived suffix) does NOT exhibit this failure —
     shown two ways: (a) the exact same "spawn independent fresh VMs" method
     used to prove the old mechanism collides, applied to the new mechanism,
     produces distinct slugs every time, because `Ecto.UUID.generate/0`'s
     122 bits of randomness are not seeded from any counter or value that
     resets across VM restarts; and (b) a `StreamData` property test
     generating thousands of `unique_slug/1` calls within a single run and
     asserting zero collisions.

  ## Why this is proven by spawning real OS processes, not "simulated"

  `System.unique_integer/1`'s own documentation states its uniqueness
  guarantee is scoped to "the current runtime system instance" — i.e. one
  BEAM VM run, not across runs. There is no supported way to reset that
  counter within a single running VM to fake a "VM restart", and faking one
  with a hand-picked low integer would only be *asserting* the bug, not
  *proving* it. Spawning `elixir -e ...` as a separate OS process is not a
  simulation — each invocation genuinely is a fresh BEAM VM, mechanically
  identical (for this counter's purposes) to what happens when a killed
  `mix test` run is followed by a fresh one. This gives a literal
  fail-then-pass demonstration for this specific bug class, rather than the
  property-test-only fallback this class of VM-restart bug would otherwise
  require.

  See `lib/letflow/design/iss059-flaky-slug-collision-fix.md` for the full
  fix design and the 30-file edit-pattern table, and
  `test/support/tenant_slug.ex` for the fixed helper itself.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Letflow.TenantSlugFixture

  # A bare `elixir -e` script (no Mix/app boot needed) computing exactly the
  # expression every one of the 30 affected files' pre-fix `insert_tenant!/0`
  # used: the first `unique_integer/1` call in a fresh VM.
  @old_mechanism_script "IO.write(System.unique_integer([:positive, :monotonic]))"

  # Regression for ISS-0059: proves the pre-fix `unique_integer/1` slug
  # mechanism collides across independent BEAM VM runs.
  describe "pre-fix mechanism collides across VM runs" do
    # Three independent, freshly-started BEAM VMs produce the identical
    # first unique_integer/1 value, i.e. the identical slug.
    test "collides across three fresh VMs" do
      # Each System.cmd call below launches a brand-new OS process running a
      # brand-new BEAM VM -- this is a real VM restart, not a stand-in for
      # one.
      results =
        for _ <- 1..3 do
          {output, 0} = System.cmd("elixir", ["-e", @old_mechanism_script])
          output
        end

      old_slug = fn counter_value -> "req027-#{counter_value}" end
      slugs = Enum.map(results, old_slug)

      # This IS the bug: every "VM run" (crash-before-cleanup, then a fresh
      # `mix test` invocation) produces the same slug for the same file
      # prefix. Against a real `tenants_slug_index` unique constraint, the
      # second and third of these would each raise
      # `Ecto.InvalidChangesetError, tenants_slug_index has already been
      # taken` if the first run's row was never rolled back -- exactly
      # ISS-0059's observed symptom.
      assert Enum.uniq(slugs) == [hd(slugs)],
             "expected the pre-fix mechanism to collide across independent VM runs (that is the bug), got distinct slugs: #{inspect(slugs)}"
    end
  end

  # Proves the POST-FIX mechanism does not exhibit the same failure, using
  # the identical "spawn independent fresh VMs" method as the pre-fix case
  # above, applied to Letflow.TenantSlugFixture.unique_slug/1 instead.
  describe "post-fix unique_slug/1 avoids the cross-VM collision" do
    # Three independent, freshly-started BEAM VMs each computing
    # unique_slug/1 produce three distinct slugs.
    #
    # Heavier than the pre-fix case's bare `elixir -e` script because
    # Ecto.UUID.generate/0 needs `:ecto` on the code path, so each of the
    # three subprocesses boots via `mix run --no-start` instead of a raw
    # `elixir` invocation. Tagged :slow so a leaner CI profile can exclude it.
    @tag :slow
    test "distinct slugs across three fresh VMs" do
      script = ~s|IO.write(Letflow.TenantSlugFixture.unique_slug("req027"))|

      results =
        for _ <- 1..3 do
          {output, 0} =
            System.cmd("mix", ["run", "--no-start", "-e", script],
              env: [{"MIX_ENV", "test"}],
              stderr_to_stdout: false
            )

          output
        end

      # Every result has the fixed "req027-" prefix and a 36-character UUID
      # suffix, and -- unlike the old mechanism above -- all three are
      # distinct, because Ecto.UUID.generate/0's randomness is not seeded
      # from any counter or value that resets across VM restarts.
      assert Enum.all?(results, &String.starts_with?(&1, "req027-"))
      assert length(Enum.uniq(results)) == 3
    end
  end

  # Property coverage: no collisions across a large number of calls within a
  # single VM run (complements the cross-VM cases above).
  describe "unique_slug/1 property coverage" do
    # Generating thousands of slugs from arbitrary prefixes never produces a
    # duplicate.
    property "no duplicates across thousands of calls" do
      check all(
              prefixes <-
                StreamData.list_of(
                  StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
                  length: 2_000
                ),
              max_runs: 1
            ) do
        slugs = Enum.map(prefixes, &TenantSlugFixture.unique_slug/1)

        assert length(Enum.uniq(slugs)) == length(slugs)
      end
    end

    # unique_slug/1 always returns "<prefix>-<36-char UUID>", regardless of
    # call order or repetition count.
    property "stable \"<prefix>-<uuid>\" format regardless of call order/count" do
      check all(prefix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
                repeat_count <- StreamData.integer(1..25),
                max_runs: 30) do
        slugs = for _ <- 1..repeat_count, do: TenantSlugFixture.unique_slug(prefix)

        assert Enum.all?(slugs, &String.starts_with?(&1, prefix <> "-"))
        assert Enum.all?(slugs, fn slug -> String.length(slug) == String.length(prefix) + 1 + 36 end)
        assert length(Enum.uniq(slugs)) == length(slugs)
      end
    end
  end
end
