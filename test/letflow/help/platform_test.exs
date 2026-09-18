defmodule Letflow.Help.PlatformTest do
  @moduledoc """
  Tests for REQ-365's `Letflow.Help.Platform` context module: `create_draft/1`,
  `update_draft/2`, `publish/1`, `reconfirm/1`, `withdraw/1`, `get_by_screen/1`. See
  `test/specs/REQ-365.md` for the acceptance-criteria mapping and
  `lib/letflow/design/req365-platform-help-authoring.md` for the design this file
  verifies against.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database. Unlike `test/letflow/help_test.exs`,
  `platform_help_content` is NOT tenant-scoped (design §1) -- it lives once in the
  `public`/default schema, so there is no `provisioned_tenant/1` step here: every test
  runs directly against `Letflow.Repo` inside the sandboxed transaction `DataCase`
  already checks out.

  Every test uses `unique_screen_id/1` (`System.unique_integer/1`-suffixed) -- no shared
  or hard-coded identifiers, no test depends on another test's data or execution order
  (`docs/guides/test_developer_guide.md` §1's determinism rule).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Help.Platform
  alias Letflow.Help.PlatformHelpContent

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp unique_screen_id(prefix \\ "req365-screen") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp draft_attrs(overrides) do
    Map.merge(
      %{
        screen_id: unique_screen_id(),
        title: "How to use this screen",
        body: "# Heading\n\nSome **bold** help text.",
        created_by: Platform.agent_pipeline_author_id()
      },
      overrides
    )
  end

  defp create_draft!(overrides \\ %{}) do
    assert {:ok, help} = Platform.create_draft(draft_attrs(overrides))
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
  # create_draft/1
  # ---------------------------------------------------------------------------------

  describe "create_draft/1" do
    test "creates a new row with status :draft and confirmed_at nil, regardless of extra whitelisted fields" do
      help = create_draft!()

      assert help.status == :draft
      assert help.confirmed_at == nil
      assert help.confirmed_for_definition_version == nil
      assert help.media == []
    end

    test "rejects a caller-supplied :status" do
      assert {:error, :status_not_accepted} =
               Platform.create_draft(draft_attrs(%{status: :live}))
    end

    test "rejects a caller-supplied :confirmed_at" do
      assert {:error, :confirmed_at_not_accepted} =
               Platform.create_draft(draft_attrs(%{confirmed_at: DateTime.utc_now()}))
    end

    test "rejects a caller-supplied :confirmed_for_definition_version" do
      assert {:error, :confirmed_for_definition_version_not_accepted} =
               Platform.create_draft(draft_attrs(%{confirmed_for_definition_version: "9.9.9"}))
    end

    test "rejects a non-nil :process_definition_id (design §3.3 -- OQ-2 unresolved)" do
      assert {:error, :process_definition_id_not_supported} =
               Platform.create_draft(draft_attrs(%{process_definition_id: Ecto.UUID.generate()}))
    end

    test "omitting :process_definition_id entirely succeeds, leaving it nil" do
      help = create_draft!()

      assert help.process_definition_id == nil
    end

    # ------------------------------------------------------------------------------
    # AC2 -- "the write path enforces the same sanitization rule REQ-363/364
    # established for tenant-scoped content", demonstrated from the platform call
    # site specifically (Letflow.Help.MarkdownSafety via PlatformHelpContent).
    # ------------------------------------------------------------------------------

    test "rejects a body containing a raw <script> tag" do
      assert {:error, changeset} =
               Platform.create_draft(
                 draft_attrs(%{body: "before <script>alert(1)</script> after"})
               )

      assert "must not contain raw HTML tags" in errors_on(changeset).body
    end

    test "rejects a title containing a raw HTML tag" do
      assert {:error, changeset} =
               Platform.create_draft(draft_attrs(%{title: "<b>bold title</b>"}))

      assert "must not contain raw HTML tags" in errors_on(changeset).title
    end

    test "rejects a markdown link with a javascript: URL scheme" do
      assert {:error, changeset} =
               Platform.create_draft(draft_attrs(%{body: "click [here](javascript:alert(1))"}))

      assert "must not contain javascript:/data:/vbscript: link or image URLs" in errors_on(
               changeset
             ).body
    end

    test "rejects a markdown image with a data: URL scheme" do
      assert {:error, changeset} =
               Platform.create_draft(draft_attrs(%{body: "![alt](data:text/html;base64,abcd)"}))

      assert "must not contain javascript:/data:/vbscript: link or image URLs" in errors_on(
               changeset
             ).body
    end

    test "allows the design's own safe markdown subset -- headings, emphasis, a plain https link" do
      body = """
      # Heading

      *italic* and **bold** text, with a [safe link](https://example.test/path).
      """

      assert {:ok, help} = Platform.create_draft(draft_attrs(%{body: body}))
      assert help.body == body
    end
  end

  # ---------------------------------------------------------------------------------
  # update_draft/2
  # ---------------------------------------------------------------------------------

  describe "update_draft/2" do
    test "updates a draft's title/body while it is still :draft" do
      help = create_draft!()

      assert {:ok, updated} =
               Platform.update_draft(help.id, %{title: "New title", body: "New body"})

      assert updated.title == "New title"
      assert updated.body == "New body"
      assert updated.status == :draft
    end

    test "rejects raw HTML on update, same as create" do
      help = create_draft!()

      assert {:error, changeset} =
               Platform.update_draft(help.id, %{body: "<img src=x onerror=alert(1)>"})

      assert "must not contain raw HTML tags" in errors_on(changeset).body
    end

    test "returns {:error, :not_a_draft} when the row is already :live" do
      help = create_draft!()
      assert {:ok, live} = Platform.publish(help.id)

      assert {:error, :not_a_draft} =
               Platform.update_draft(live.id, %{title: "won't apply"})
    end

    test "rejects a non-nil :process_definition_id on update too" do
      help = create_draft!()

      assert {:error, :process_definition_id_not_supported} =
               Platform.update_draft(help.id, %{process_definition_id: Ecto.UUID.generate()})
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} =
               Platform.update_draft(Ecto.UUID.generate(), %{title: "x"})
    end
  end

  # ---------------------------------------------------------------------------------
  # publish/1 -- AC: "publish sets confirmed_at from the real clock, never a
  # caller-supplied value" (publish/1 takes no attrs parameter at all).
  # ---------------------------------------------------------------------------------

  describe "publish/1" do
    test "moves :draft -> :live and sets confirmed_at from the real clock" do
      help = create_draft!()

      before_publish = DateTime.utc_now()
      assert {:ok, published} = Platform.publish(help.id)
      after_publish = DateTime.utc_now()

      assert published.status == :live
      assert published.confirmed_at != nil
      assert DateTime.compare(published.confirmed_at, before_publish) in [:gt, :eq]
      assert DateTime.compare(published.confirmed_at, after_publish) in [:lt, :eq]
    end

    test "confirmed_for_definition_version stays nil after publish" do
      help = create_draft!()

      assert {:ok, published} = Platform.publish(help.id)

      assert published.confirmed_for_definition_version == nil
    end

    test "publish/1 takes no attrs argument -- there is no parameter through which a caller could supply confirmed_at" do
      assert {:arity, 1} = Function.info(&Platform.publish/1, :arity)
    end

    test "returns {:error, :not_a_draft} for an already-live row" do
      help = create_draft!()
      assert {:ok, live} = Platform.publish(help.id)

      assert {:error, :not_a_draft} = Platform.publish(live.id)
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = Platform.publish(Ecto.UUID.generate())
    end
  end

  # ---------------------------------------------------------------------------------
  # reconfirm/1 -- AC: "reconfirm updates only confirmed_at, body is provably
  # unchanged (tested)".
  # ---------------------------------------------------------------------------------

  describe "reconfirm/1" do
    test "bumps confirmed_at on an already-live row without changing title/body" do
      help = create_draft!()
      assert {:ok, published} = Platform.publish(help.id)

      # Ensure the clock has room to move forward measurably between the two calls.
      Process.sleep(10)

      assert {:ok, reconfirmed} = Platform.reconfirm(published.id)

      assert reconfirmed.title == published.title
      assert reconfirmed.body == published.body
      assert DateTime.compare(reconfirmed.confirmed_at, published.confirmed_at) == :gt
    end

    test "confirmed_for_definition_version stays nil after reconfirm" do
      help = create_draft!()
      assert {:ok, published} = Platform.publish(help.id)

      assert {:ok, reconfirmed} = Platform.reconfirm(published.id)

      assert reconfirmed.confirmed_for_definition_version == nil
    end

    test "reconfirm/1 takes no attrs argument -- there is no parameter through which a caller could supply confirmed_at" do
      assert {:arity, 1} = Function.info(&Platform.reconfirm/1, :arity)
    end

    test "returns {:error, :not_live} for a :draft row" do
      help = create_draft!()

      assert {:error, :not_live} = Platform.reconfirm(help.id)
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = Platform.reconfirm(Ecto.UUID.generate())
    end
  end

  # ---------------------------------------------------------------------------------
  # withdraw/1 (design §2's live -> draft transition)
  # ---------------------------------------------------------------------------------

  describe "withdraw/1" do
    test "moves :live -> :draft, after which update_draft/2 works again" do
      help = create_draft!()
      assert {:ok, published} = Platform.publish(help.id)

      assert {:ok, withdrawn} = Platform.withdraw(published.id)
      assert withdrawn.status == :draft

      assert {:ok, updated} = Platform.update_draft(withdrawn.id, %{title: "corrected"})
      assert updated.title == "corrected"
    end

    test "returns {:error, :not_live} for an already-draft row" do
      help = create_draft!()

      assert {:error, :not_live} = Platform.withdraw(help.id)
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} = Platform.withdraw(Ecto.UUID.generate())
    end
  end

  # ---------------------------------------------------------------------------------
  # get_by_screen/1
  # ---------------------------------------------------------------------------------

  describe "get_by_screen/1" do
    test "returns only rows for that screen_id" do
      screen_id = unique_screen_id()
      matching = create_draft!(%{screen_id: screen_id})
      _other_screen = create_draft!(%{screen_id: unique_screen_id()})

      assert {:ok, results} = Platform.get_by_screen(screen_id)

      assert [%PlatformHelpContent{id: id}] = results
      assert id == matching.id
    end

    test "returns an empty list for a screen_id with no content" do
      assert {:ok, []} = Platform.get_by_screen(unique_screen_id("req365-empty"))
    end
  end
end
