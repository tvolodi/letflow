defmodule Letflow.HelpTest do
  @moduledoc """
  Tests for REQ-364's `Letflow.Help` context module: `create_draft/2`, `update_draft/3`,
  `publish/2`, `reconfirm/2`, `withdraw/2`, `get_by_screen/2`, `get_by_process_definition_id/2`.
  See `docs/requirements.yaml`'s REQ-364 entry and
  `lib/letflow/design/req363-help-content-data-model.md` for the full acceptance-criteria
  and design source this file verifies against.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database. `help_content` is a per-tenant-schema table
  (design §1), so this file follows `test/letflow/definitions/store_test.exs`'s
  established `provisioned_tenant/1` + Sandbox `:auto` pattern exactly (real
  `CREATE SCHEMA`, real migration replay via `TenantProvisioning.replay_migrations/2`,
  which now includes this requirement's own `help_content` migration).

  Every test provisions its own tenant and uses `unique_screen_id/1`
  (`System.unique_integer/1`-suffixed) -- no shared or hard-coded identifiers, no test
  depends on another test's data or execution order (`docs/guides/test_developer_guide.md`
  §1's determinism rule).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Help
  alias Letflow.Help.HelpContent
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- mirrors test/letflow/definitions/store_test.exs's
  # provisioned_tenant/1 exactly.
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req364"),
        display_name: "REQ-364 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant(_context \\ %{}) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_screen_id(prefix \\ "req364-screen") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_def_name(prefix \\ "req364-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp valid_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp create_process_definition!(schema_name, version \\ "1.0.0") do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_def_name(),
                 version: version,
                 graph: valid_graph(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    definition
  end

  defp draft_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        screen_id: unique_screen_id(),
        title: "How to use this screen",
        body: "# Heading\n\nSome **bold** help text with a [link](https://example.test).",
        created_by: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp create_draft!(schema_name, overrides \\ %{}) do
    assert {:ok, help} = Help.create_draft(draft_attrs(overrides), prefix: schema_name)
    help
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ---------------------------------------------------------------------------------
  # create_draft/2
  # ---------------------------------------------------------------------------------

  describe "create_draft/2" do
    test "creates a new row with status :draft and confirmed_at nil, regardless of extra whitelisted fields" do
      %{schema_name: schema_name} = provisioned_tenant()

      help = create_draft!(schema_name)

      assert help.status == :draft
      assert help.confirmed_at == nil
      assert help.confirmed_for_definition_version == nil
      assert help.media == []
    end

    test "rejects a caller-supplied :status" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, :status_not_accepted} =
               Help.create_draft(draft_attrs(%{status: :live}), prefix: schema_name)
    end

    test "rejects a caller-supplied :confirmed_at" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, :confirmed_at_not_accepted} =
               Help.create_draft(
                 draft_attrs(%{confirmed_at: DateTime.utc_now()}),
                 prefix: schema_name
               )
    end

    test "rejects a caller-supplied :confirmed_for_definition_version" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, :confirmed_for_definition_version_not_accepted} =
               Help.create_draft(
                 draft_attrs(%{confirmed_for_definition_version: "9.9.9"}),
                 prefix: schema_name
               )
    end

    test "creating with a non-existent process_definition_id is rejected" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, :process_definition_not_found} =
               Help.create_draft(
                 draft_attrs(%{process_definition_id: Ecto.UUID.generate()}),
                 prefix: schema_name
               )
    end

    test "creating with a real process_definition_id in the same tenant schema succeeds" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = create_process_definition!(schema_name)

      help =
        create_draft!(schema_name, %{process_definition_id: definition.id})

      assert help.process_definition_id == definition.id
    end

    # ------------------------------------------------------------------------------
    # AC: "a write attempting raw HTML/script content is rejected with a clear error,
    # tested explicitly -- not merely assumed from the design" (design §5.1)
    # ------------------------------------------------------------------------------

    test "rejects a body containing a raw <script> tag" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, changeset} =
               Help.create_draft(
                 draft_attrs(%{body: "before <script>alert(1)</script> after"}),
                 prefix: schema_name
               )

      assert "must not contain raw HTML tags" in errors_on(changeset).body
    end

    test "rejects a body containing any other raw HTML tag (not just <script>)" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, changeset} =
               Help.create_draft(
                 draft_attrs(%{body: "click <div onclick=\"doEvil()\">here</div>"}),
                 prefix: schema_name
               )

      assert "must not contain raw HTML tags" in errors_on(changeset).body
    end

    test "rejects a title containing a raw HTML tag" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, changeset} =
               Help.create_draft(
                 draft_attrs(%{title: "<b>bold title</b>"}),
                 prefix: schema_name
               )

      assert "must not contain raw HTML tags" in errors_on(changeset).title
    end

    test "rejects a markdown link with a javascript: URL scheme" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, changeset} =
               Help.create_draft(
                 draft_attrs(%{body: "click [here](javascript:alert(1))"}),
                 prefix: schema_name
               )

      assert "must not contain javascript:/data:/vbscript: link or image URLs" in errors_on(
               changeset
             ).body
    end

    test "rejects a markdown image with a data: URL scheme" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, changeset} =
               Help.create_draft(
                 draft_attrs(%{body: "![alt](data:text/html;base64,abcd)"}),
                 prefix: schema_name
               )

      assert "must not contain javascript:/data:/vbscript: link or image URLs" in errors_on(
               changeset
             ).body
    end

    test "allows the design's own markdown subset -- headings, emphasis, lists, a plain https link, and a fenced code block" do
      %{schema_name: schema_name} = provisioned_tenant()

      body = """
      # Heading

      *italic* and **bold** text.

      - item one
      - item two

      1. first
      2. second

      > a blockquote

      [a safe link](https://example.test/path)

      `inline code`

      ```
      fenced code block, <not-a-real-tag> literal text here
      ```
      """

      assert {:ok, help} =
               Help.create_draft(draft_attrs(%{body: body}), prefix: schema_name)

      assert help.body == body
    end
  end

  # ---------------------------------------------------------------------------------
  # update_draft/3
  # ---------------------------------------------------------------------------------

  describe "update_draft/3" do
    test "updates a draft's title/body while it is still :draft" do
      %{schema_name: schema_name} = provisioned_tenant()
      help = create_draft!(schema_name)

      assert {:ok, updated} =
               Help.update_draft(help.id, %{title: "New title", body: "New body"},
                 prefix: schema_name
               )

      assert updated.title == "New title"
      assert updated.body == "New body"
      assert updated.status == :draft
    end

    test "rejects raw HTML on update, same as create" do
      %{schema_name: schema_name} = provisioned_tenant()
      help = create_draft!(schema_name)

      assert {:error, changeset} =
               Help.update_draft(help.id, %{body: "<img src=x onerror=alert(1)>"},
                 prefix: schema_name
               )

      assert "must not contain raw HTML tags" in errors_on(changeset).body
    end

    test "returns {:error, :not_a_draft} when the row is already :live" do
      %{schema_name: schema_name} = provisioned_tenant()
      help = create_draft!(schema_name)
      assert {:ok, live} = Help.publish(help.id, prefix: schema_name)

      assert {:error, :not_a_draft} =
               Help.update_draft(live.id, %{title: "won't apply"}, prefix: schema_name)
    end

    test "returns {:error, :not_found} for an unknown id" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, :not_found} =
               Help.update_draft(Ecto.UUID.generate(), %{title: "x"}, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # publish/2 -- AC: "publish sets confirmed_at from the real clock, never a
  # caller-supplied value"
  # ---------------------------------------------------------------------------------

  describe "publish/2" do
    test "moves :draft -> :live and sets confirmed_at from the real clock" do
      %{schema_name: schema_name} = provisioned_tenant()
      help = create_draft!(schema_name)

      before_publish = DateTime.utc_now()
      assert {:ok, published} = Help.publish(help.id, prefix: schema_name)
      after_publish = DateTime.utc_now()

      assert published.status == :live
      assert published.confirmed_at != nil
      assert DateTime.compare(published.confirmed_at, before_publish) in [:gt, :eq]
      assert DateTime.compare(published.confirmed_at, after_publish) in [:lt, :eq]
    end

    test "publish/2 takes no attrs argument at all -- there is no parameter through which a caller could supply confirmed_at" do
      assert {:arity, 2} = Function.info(&Help.publish/2, :arity)
    end

    test "for process-scoped help, records confirmed_for_definition_version from the process definition's actual current version" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = create_process_definition!(schema_name, "2.7.1")
      help = create_draft!(schema_name, %{process_definition_id: definition.id})

      assert {:ok, published} = Help.publish(help.id, prefix: schema_name)

      assert published.confirmed_for_definition_version == "2.7.1"
    end

    test "for non-process-scoped help, confirmed_for_definition_version stays nil" do
      %{schema_name: schema_name} = provisioned_tenant()
      help = create_draft!(schema_name)

      assert {:ok, published} = Help.publish(help.id, prefix: schema_name)

      assert published.confirmed_for_definition_version == nil
    end

    test "returns {:error, :not_a_draft} for an already-live row" do
      %{schema_name: schema_name} = provisioned_tenant()
      help = create_draft!(schema_name)
      assert {:ok, live} = Help.publish(help.id, prefix: schema_name)

      assert {:error, :not_a_draft} = Help.publish(live.id, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # reconfirm/2 -- AC: "reconfirm updates only confirmed_at, body is provably
  # unchanged (tested)"; AC: confirmed_for_definition_version recorded from the
  # process's actual current version at reconfirm time too, not caller-supplied.
  # ---------------------------------------------------------------------------------

  describe "reconfirm/2" do
    test "bumps confirmed_at on an already-live row without changing title/body" do
      %{schema_name: schema_name} = provisioned_tenant()
      help = create_draft!(schema_name)
      assert {:ok, published} = Help.publish(help.id, prefix: schema_name)

      # Ensure the clock has room to move forward measurably between the two calls.
      Process.sleep(10)

      assert {:ok, reconfirmed} = Help.reconfirm(published.id, prefix: schema_name)

      assert reconfirmed.title == published.title
      assert reconfirmed.body == published.body
      assert DateTime.compare(reconfirmed.confirmed_at, published.confirmed_at) == :gt
    end

    test "reconfirm/2 takes no attrs argument -- there is no parameter through which a caller could supply confirmed_at" do
      assert {:arity, 2} = Function.info(&Help.reconfirm/2, :arity)
    end

    test "refreshes confirmed_for_definition_version from the process definition's actual current version" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = create_process_definition!(schema_name, "3.0.0")
      help = create_draft!(schema_name, %{process_definition_id: definition.id})
      assert {:ok, published} = Help.publish(help.id, prefix: schema_name)
      assert published.confirmed_for_definition_version == "3.0.0"

      assert {:ok, reconfirmed} = Help.reconfirm(published.id, prefix: schema_name)

      assert reconfirmed.confirmed_for_definition_version == "3.0.0"
    end

    test "returns {:error, :not_live} for a :draft row" do
      %{schema_name: schema_name} = provisioned_tenant()
      help = create_draft!(schema_name)

      assert {:error, :not_live} = Help.reconfirm(help.id, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # withdraw/2 (design §2's live -> draft transition)
  # ---------------------------------------------------------------------------------

  describe "withdraw/2" do
    test "moves :live -> :draft, after which update_draft/3 works again" do
      %{schema_name: schema_name} = provisioned_tenant()
      help = create_draft!(schema_name)
      assert {:ok, published} = Help.publish(help.id, prefix: schema_name)

      assert {:ok, withdrawn} = Help.withdraw(published.id, prefix: schema_name)
      assert withdrawn.status == :draft

      assert {:ok, updated} =
               Help.update_draft(withdrawn.id, %{title: "corrected"}, prefix: schema_name)

      assert updated.title == "corrected"
    end

    test "returns {:error, :not_live} for an already-draft row" do
      %{schema_name: schema_name} = provisioned_tenant()
      help = create_draft!(schema_name)

      assert {:error, :not_live} = Help.withdraw(help.id, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # get_by_screen/2, get_by_process_definition_id/2
  # ---------------------------------------------------------------------------------

  describe "get_by_screen/2 and get_by_process_definition_id/2" do
    test "get_by_screen/2 returns only rows for that screen_id, tenant-scoped by prefix" do
      %{schema_name: schema_name} = provisioned_tenant()
      %{schema_name: other_schema_name} = provisioned_tenant()

      screen_id = unique_screen_id()
      matching = create_draft!(schema_name, %{screen_id: screen_id})
      _other_screen = create_draft!(schema_name, %{screen_id: unique_screen_id()})
      _other_tenant_same_screen_id = create_draft!(other_schema_name, %{screen_id: screen_id})

      assert {:ok, results} = Help.get_by_screen(screen_id, prefix: schema_name)

      assert [%HelpContent{id: id}] = results
      assert id == matching.id
    end

    test "get_by_process_definition_id/2 returns only rows scoped to that process definition" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = create_process_definition!(schema_name)
      other_definition = create_process_definition!(schema_name)

      matching = create_draft!(schema_name, %{process_definition_id: definition.id})
      _other = create_draft!(schema_name, %{process_definition_id: other_definition.id})
      _unscoped = create_draft!(schema_name)

      assert {:ok, results} =
               Help.get_by_process_definition_id(definition.id, prefix: schema_name)

      assert [%HelpContent{id: id}] = results
      assert id == matching.id
    end
  end
end
