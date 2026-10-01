defmodule Letflow.ServiceCatalog.EndpointUrlValidationTest do
  @moduledoc """
  ISS-0950 regression tests: syntactic `endpoint_url` validation at catalog
  register/publish time. See `test/specs/ISS-0950.md` for the matrix-row ->
  test mapping and rationale. Design authority:
  `lib/letflow/design/iss0950-catalog-endpoint-url-register-validation.md`.

  The dispatch-time INV-9 gate stays binding; these tests pin the *earlier*,
  advisory check (`Entry.check_endpoint_url/1`, wired into
  `Entry.insert_changeset/2` and `Entry.publish_changeset/2`), including the
  traps the design names: `validate_change` skipping an unchanged URL on
  republish (D5), absent-key semantics on publish, and rollback of the archive
  insert on a rejected publish (D7).

  `async: false` and per-test `on_exit` cleanup for the same reason
  `service_catalog_test.exs` documents: `service_catalog` is a GLOBAL table.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Iss0950EndpointUrlFixtures, as: Fx
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version
  alias Letflow.Webhooks.UrlValidator

  @good_url "https://example.test/svc"
  @legacy_bad_url "http://legacy.example.test/svc"

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # -- helpers ------------------------------------------------------------

  defp unique_service_id do
    "iss0950-svc-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(v in Version, where: v.service_id == ^service_id))
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp register_attrs(overrides) do
    Map.merge(
      %{
        service_id: unique_service_id(),
        endpoint_url: @good_url,
        required_auth: :NONE,
        timeout_ms: 5_000,
        scope: :global
      },
      overrides
    )
  end

  defp register!(overrides) do
    attrs = register_attrs(overrides)
    on_exit(fn -> cleanup_entry!(attrs.service_id) end)
    assert {:ok, entry} = ServiceCatalog.register(attrs)
    entry
  end

  # Seeds a row whose stored endpoint_url is invalid, bypassing every
  # changeset (legacy data written before ISS-0950).
  defp seed_legacy!(stored_url) do
    entry = register!(%{})

    {1, _} =
      Repo.update_all(from(e in Entry, where: e.service_id == ^entry.service_id),
        set: [endpoint_url: stored_url]
      )

    Repo.get!(Entry, entry.service_id)
  end

  defp version_count(service_id) do
    Repo.aggregate(from(v in Version, where: v.service_id == ^service_id), :count)
  end

  defp endpoint_url_errors(%Ecto.Changeset{errors: errors}) do
    for {:endpoint_url, err} <- errors, do: err
  end

  defp assert_not_allowed_error(%Ecto.Changeset{} = cs, url) do
    assert [{msg, opts}] = endpoint_url_errors(cs),
           "expected exactly one error for #{inspect(url)}"

    assert msg == Fx.message()
    assert opts[:validation] == :endpoint_url_not_allowed
  end

  # -- E: Entry.check_endpoint_url/1 (pure) ---------------------------------

  describe "Entry.check_endpoint_url/1" do
    test "every REJECT row returns {:error, :endpoint_url_not_allowed}" do
      assert length(Fx.reject_urls()) == 23

      for {id, url} <- Fx.reject_urls() do
        assert Entry.check_endpoint_url(url) == {:error, :endpoint_url_not_allowed},
               "#{id}: expected #{inspect(url)} to be rejected"
      end
    end

    test "every ACCEPT row returns :ok" do
      assert length(Fx.accept_urls()) == 10

      for {id, url} <- Fx.accept_urls() do
        assert Entry.check_endpoint_url(url) == :ok,
               "#{id}: expected #{inspect(url)} to be accepted"
      end
    end

    test "a placeholder is only tolerated AFTER the host: path/query/fragment yes, authority no" do
      assert :ok = Entry.check_endpoint_url("https://example.test/{{variables.a}}")
      assert :ok = Entry.check_endpoint_url("https://example.test?x={{variables.a}}")
      assert :ok = Entry.check_endpoint_url("https://example.test\#{{variables.a}}")

      assert {:error, :endpoint_url_not_allowed} =
               Entry.check_endpoint_url("https://example.test{{variables.a}}")

      assert {:error, :endpoint_url_not_allowed} =
               Entry.check_endpoint_url("https://{{variables.a}}.example.test/x")
    end

    test "the dispatch-gate validator (validate/1) still rejects every non-templated REJECT row, and check_endpoint_url/1 is no looser" do
      # Templated rows are excluded: validate/1 has no notion of templates. For
      # every other REJECT row validate/1 (IP literals short-circuit before DNS;
      # the rest fail on scheme/host) refuses the same URL.
      for {id, url} <- Fx.reject_urls(), not String.contains?(url, "{{") do
        assert {:error, :target_url_not_allowed} = UrlValidator.validate(url),
               "#{id}: dispatch-gate validator no longer rejects #{inspect(url)}"

        assert {:error, :endpoint_url_not_allowed} = Entry.check_endpoint_url(url)
      end
    end

    test "validate/2 (with DNS) still rejects a hostname that resolves privately, which check_endpoint_url/1 by design accepts" do
      url = "https://rebind.example.test/svc"
      assert :ok = Entry.check_endpoint_url(url)

      assert {:error, :target_url_not_allowed} =
               UrlValidator.validate(url, fn _ -> {:ok, [{:inet, {10, 0, 0, 1}, []}]} end)
    end

    test "check_endpoint_url/1 never resolves a hostname (resolver-free by construction)" do
      # A hostname that cannot resolve anywhere is still accepted: no DNS is consulted.
      assert :ok = Entry.check_endpoint_url("https://no-such-host.invalid/svc")
    end
  end

  # -- R: ServiceCatalog.register/1 ----------------------------------------

  describe "ServiceCatalog.register/1" do
    test "every REJECT row returns {:error, changeset} with the D4 error, and leaves NO row (R-NO-ROW)" do
      for {id, url} <- Fx.reject_urls() do
        attrs = register_attrs(%{endpoint_url: url})
        on_exit(fn -> cleanup_entry!(attrs.service_id) end)

        assert {:error, %Ecto.Changeset{} = cs} = ServiceCatalog.register(attrs),
               "#{id}: expected #{inspect(url)} to be rejected"

        assert_not_allowed_error(cs, url)
        refute Repo.get(Entry, attrs.service_id), "#{id}: a row was left behind"
      end
    end

    test "every ACCEPT row returns {:ok, entry} and persists the URL verbatim" do
      for {id, url} <- Fx.accept_urls() do
        entry = register!(%{endpoint_url: url})
        assert entry.endpoint_url == url, "#{id}: URL not persisted verbatim"
        assert Repo.get!(Entry, entry.service_id).endpoint_url == url
      end
    end

    test "R-LEN: an over-length URL yields exactly ONE :endpoint_url error (the length error), not two" do
      long = "https://example.test/" <> String.duplicate("a", 2049 - 21)
      assert String.length(long) == 2049

      assert {:error, %Ecto.Changeset{} = cs} =
               ServiceCatalog.register(register_attrs(%{endpoint_url: long}))

      assert [{_msg, opts}] = endpoint_url_errors(cs)
      assert opts[:validation] == :length
    end

    test "R-MISSING: absent key, nil, \"\" and whitespace-only each yield exactly ONE :endpoint_url error - the required one" do
      absent = Map.delete(register_attrs(%{}), :endpoint_url)

      variants = [
        {"absent key", absent},
        {"nil", register_attrs(%{endpoint_url: nil})},
        {"empty string", register_attrs(%{endpoint_url: ""})},
        {"whitespace", register_attrs(%{endpoint_url: "   "})}
      ]

      for {label, attrs} <- variants do
        on_exit(fn -> cleanup_entry!(attrs.service_id) end)
        assert {:error, %Ecto.Changeset{} = cs} = ServiceCatalog.register(attrs), label
        assert [{msg, opts}] = endpoint_url_errors(cs), "#{label}: expected exactly one error"
        assert opts[:validation] == :required, label
        refute msg == Fx.message(), label
      end
    end
  end

  # -- P: ServiceCatalog.publish/3 -----------------------------------------

  describe "ServiceCatalog.publish/3" do
    test "every REJECT row returns {:error, changeset}; live row and version history are byte-identical afterwards (P-ROLLBACK)" do
      for {id, url} <- Fx.reject_urls() do
        entry = register!(%{})
        before_row = Repo.get!(Entry, entry.service_id)
        before_versions = version_count(entry.service_id)

        assert {:error, %Ecto.Changeset{} = cs} =
                 ServiceCatalog.publish(entry.service_id, "2", %{
                   endpoint_url: url,
                   timeout_ms: 6_000
                 }),
               "#{id}: expected #{inspect(url)} to be rejected"

        assert_not_allowed_error(cs, url)

        assert Repo.get!(Entry, entry.service_id) == before_row,
               "#{id}: live row changed by a rejected publish"

        assert version_count(entry.service_id) == before_versions,
               "#{id}: archive insert was not rolled back"
      end
    end

    test "every ACCEPT row returns {:ok, entry} with the URL persisted and the previous version archived" do
      for {id, url} <- Fx.accept_urls() do
        entry = register!(%{})

        assert {:ok, updated} =
                 ServiceCatalog.publish(entry.service_id, "2", %{
                   endpoint_url: url,
                   timeout_ms: 6_000
                 }),
               "#{id}: expected #{inspect(url)} to be accepted"

        assert updated.endpoint_url == url
        assert version_count(entry.service_id) == 1
      end
    end

    test "P-SAME-URL: republishing a legacy bad URL UNCHANGED is rejected (a validate_change-based check would skip it)" do
      legacy = seed_legacy!(@legacy_bad_url)

      assert {:error, %Ecto.Changeset{} = cs} =
               ServiceCatalog.publish(legacy.service_id, "2", %{
                 endpoint_url: @legacy_bad_url,
                 timeout_ms: 6_000
               })

      assert_not_allowed_error(cs, @legacy_bad_url)
      assert Repo.get!(Entry, legacy.service_id).endpoint_url == @legacy_bad_url
      assert version_count(legacy.service_id) == 0
    end

    test "P-SAME-URL: the admin can repair a legacy bad row by publishing a good URL" do
      legacy = seed_legacy!(@legacy_bad_url)

      assert {:ok, updated} =
               ServiceCatalog.publish(legacy.service_id, "2", %{
                 endpoint_url: @good_url,
                 timeout_ms: 6_000
               })

      assert updated.endpoint_url == @good_url
      # the legacy value is archived verbatim, not re-validated
      assert [archived] = Repo.all(from(v in Version, where: v.service_id == ^legacy.service_id))
      assert archived.endpoint_url == @legacy_bad_url
    end

    test "P-SAME-URL: republishing an unchanged GOOD URL still succeeds" do
      entry = register!(%{})

      assert {:ok, updated} =
               ServiceCatalog.publish(entry.service_id, "2", %{
                 endpoint_url: @good_url,
                 timeout_ms: 6_000
               })

      assert updated.endpoint_url == @good_url
    end

    test "R-MISSING (publish): explicit nil, \"\" and whitespace-only each yield exactly ONE :endpoint_url error - the required one, and roll back" do
      for {label, value} <- [{"nil", nil}, {"empty string", ""}, {"whitespace", "   "}] do
        entry = register!(%{})

        assert {:error, %Ecto.Changeset{} = cs} =
                 ServiceCatalog.publish(entry.service_id, "2", %{
                   endpoint_url: value,
                   timeout_ms: 6_000
                 }),
               label

        assert [{msg, opts}] = endpoint_url_errors(cs), "#{label}: expected exactly one error"
        assert opts[:validation] == :required, label
        refute msg == Fx.message(), label
        assert version_count(entry.service_id) == 0, label
      end
    end

    test "P-ABSENT (a): key omitted + good stored URL -> publish succeeds and INHERITS the stored URL" do
      entry = register!(%{endpoint_url: "https://example.test/stored"})

      assert {:ok, updated} = ServiceCatalog.publish(entry.service_id, "2", %{timeout_ms: 6_000})

      assert updated.endpoint_url == "https://example.test/stored"
      assert Repo.get!(Entry, entry.service_id).endpoint_url == "https://example.test/stored"
      assert version_count(entry.service_id) == 1
    end

    test "P-ABSENT (b): key omitted + legacy bad stored URL -> rejected with the not-allowed error ONLY (no required error), and rolled back" do
      legacy = seed_legacy!(@legacy_bad_url)
      before_row = Repo.get!(Entry, legacy.service_id)

      assert {:error, %Ecto.Changeset{} = cs} =
               ServiceCatalog.publish(legacy.service_id, "2", %{timeout_ms: 6_000})

      assert_not_allowed_error(cs, @legacy_bad_url)
      assert Repo.get!(Entry, legacy.service_id) == before_row
      assert version_count(legacy.service_id) == 0
    end
  end

  # -- untouched paths ------------------------------------------------------

  describe "paths that take no endpoint_url input" do
    test "UNTOUCHED-PATHS: update_scope/2 and retire/1 still succeed on a legacy-bad-URL row" do
      legacy = seed_legacy!(@legacy_bad_url)

      assert {:ok, scoped} = ServiceCatalog.update_scope(legacy.service_id, %{scope: :global})
      assert scoped.endpoint_url == @legacy_bad_url

      assert {:ok, retired} = ServiceCatalog.retire(legacy.service_id)
      assert retired.status == :RETIRED
      assert retired.endpoint_url == @legacy_bad_url
    end
  end
end
