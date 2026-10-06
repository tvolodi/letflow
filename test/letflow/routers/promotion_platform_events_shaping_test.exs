defmodule Letflow.Routers.PromotionPlatformEventsShapingTest do
  @moduledoc """
  REQ-446 T-7 (`lib/letflow/design/req446-named-scoped-permissions.md` section 4a / 5):
  INV-10 response shaping on `GET /promotions/platform-events`. A caller that is not a
  platform-tenant operator never receives a tenant id other than its own in an event payload;
  an operator sees payloads unchanged. See `test/specs/REQ-446.md`.

  Events are written into the schema under test through the real producers' adapters
  (`Letflow.EventStore.PlatformEvents`) for the three seeded promotion event types, and through
  `Letflow.EventStore.append_platform_event/2` with a registered permissive fixture type for the
  nested and non-binary cases. "The operator promoted B into A" is simulated by writing the
  `DEFINITION_PROMOTED` event the promotion transaction would write: source B, target A.

  `async: false` (VM-global platform pin); the pin is restored by the fixture's `on_exit`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Pagination
  alias Letflow.EventStore.PlatformEvents
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp get_events(fixture, roles, query \\ "") do
    path = if query == "", do: "/platform-events", else: "/platform-events?" <> query

    Letflow.Routers.Promotions.call(
      Fixture.router_conn(:get, path, fixture, roles, nil),
      Letflow.Routers.Promotions.init([])
    )
  end

  defp decode_items(resp) do
    assert resp.status == 200, "answered #{resp.status}: #{resp.resp_body}"
    Jason.decode!(resp.resp_body)["items"]
  end

  defp by_id(items), do: Map.new(items, &{&1["event_id"], &1})

  # Seeds the shared scenario into `fixture`'s schema, in sequence order, with `other`
  # standing for the foreign tenant. Each entry carries the payload as stored and the payload a
  # NON-operator must receive (written by hand, not derived with the walk under test).
  defp seed!(fixture, other) do
    own = fixture.tenant_id
    foreign = other.tenant_id
    prefix = fixture.schema_name

    promoted = fn source, target ->
      stored = %{
        "review_id" => Ecto.UUID.generate(),
        "source_tenant_id" => source,
        "target_tenant_id" => target,
        "source_definition_id" => Ecto.UUID.generate(),
        "target_definition_id" => Ecto.UUID.generate(),
        "process_key" => Scope.unique_key("pk")
      }

      attrs =
        for {k, v} <- stored, into: %{}, do: {String.to_existing_atom(k), v}

      {:ok, %{event_id: id}} =
        PlatformEvents.append_definition_promoted(
          Map.merge(attrs, %{event_type: "DEFINITION_PROMOTED", actor_id: Ecto.UUID.generate()}),
          prefix
        )

      {id, "DEFINITION_PROMOTED", stored}
    end

    teardown = fn tenant_id ->
      stored = %{
        "run_id" => Ecto.UUID.generate(),
        "sandbox_id" => Ecto.UUID.generate(),
        "tenant_id" => tenant_id,
        "error" => "sandbox release failed"
      }

      attrs = for {k, v} <- stored, into: %{}, do: {String.to_existing_atom(k), v}

      {:ok, %{event_id: id}} =
        PlatformEvents.append_promotion_assertion_teardown_failed(
          Map.put(attrs, :event_type, "PROMOTION_ASSERTION_TEARDOWN_FAILED"),
          prefix
        )

      {id, "PROMOTION_ASSERTION_TEARDOWN_FAILED", stored}
    end

    rolled_back = fn ->
      stored = %{
        "process_key" => Scope.unique_key("pk"),
        "from_version" => "2.0.0",
        "to_version" => "1.0.0"
      }

      attrs = for {k, v} <- stored, into: %{}, do: {String.to_existing_atom(k), v}

      {:ok, %{event_id: id}} =
        PlatformEvents.append_definition_version_rolled_back(
          Map.merge(attrs, %{
            event_type: "DEFINITION_VERSION_ROLLED_BACK",
            actor_id: Ecto.UUID.generate()
          }),
          prefix
        )

      {id, "DEFINITION_VERSION_ROLLED_BACK", stored}
    end

    fixture_event = fn stored ->
      {type, id} = Scope.append_fixture_event!(fixture, stored)
      {id, type, stored}
    end

    e1 = promoted.(foreign, own)
    e2 = teardown.(foreign)
    e3 = promoted.(own, own)
    e4 = teardown.(own)
    e4b = teardown.(String.upcase(own))
    e5 = rolled_back.()

    e6 =
      fixture_event.(%{
        "detail" => %{
          "origin_tenant_id" => foreign,
          "items" => [
            %{"tenant_id" => foreign, "n" => 1},
            %{"tenant_id" => own, "n" => 2}
          ]
        },
        "note" => "hello"
      })

    e7 = fixture_event.(%{"tenant_id" => 5, "keep" => "x"})

    e8 =
      fixture_event.(%{
        "x" => [[%{"tenant_id" => foreign}, %{"tenant_id" => own, "k" => 1}]],
        "y" => 7
      })

    expected = fn {id, type, stored}, shaped ->
      %{id: id, type: type, stored: stored, shaped: shaped}
    end

    [
      expected.(
        e1,
        Map.drop(elem(e1, 2), ["source_tenant_id", "source_definition_id", "review_id"])
      ),
      expected.(e2, Map.drop(elem(e2, 2), ["tenant_id", "error"])),
      expected.(e3, Map.drop(elem(e3, 2), ["source_definition_id", "review_id"])),
      expected.(e4, Map.delete(elem(e4, 2), "error")),
      expected.(e4b, Map.delete(elem(e4b, 2), "error")),
      expected.(e5, elem(e5, 2)),
      # the fixture type is not allowlisted: unknown event type, payload is empty
      expected.(e6, %{}),
      expected.(e7, %{}),
      expected.(e8, %{})
    ]
  end

  describe "non-operator callers" do
    test "non_operator_never_receives_a_foreign_tenant_id", ctx do
      seeded = seed!(ctx.a, ctx.b)

      resp = get_events(ctx.a, ["TENANT_ADMIN"])
      assert resp.status == 200

      refute resp.resp_body =~ ctx.b.tenant_id
      refute resp.resp_body =~ String.upcase(ctx.b.tenant_id)

      items = resp |> decode_items() |> by_id()
      [e1, e2, e3, e4, e4b, _e5, e6, e7, _e8] = seeded

      assert items[e1.id]["payload"] |> Map.has_key?("source_tenant_id") == false
      assert items[e1.id]["payload"]["target_tenant_id"] == ctx.a.tenant_id
      assert Map.has_key?(items[e2.id]["payload"], "tenant_id") == false
      assert items[e3.id]["payload"]["source_tenant_id"] == ctx.a.tenant_id
      assert items[e3.id]["payload"]["target_tenant_id"] == ctx.a.tenant_id
      assert items[e4.id]["payload"]["tenant_id"] == ctx.a.tenant_id
      assert items[e4b.id]["payload"]["tenant_id"] == String.upcase(ctx.a.tenant_id)

      assert items[e6.id]["payload"] == %{}
      assert items[e7.id]["payload"] == %{}
    end

    test "own_tenant_id_is_retained", ctx do
      seeded = seed!(ctx.a, ctx.b)
      items = ctx.a |> get_events(["TENANT_ADMIN"]) |> decode_items() |> by_id()

      own = ctx.a.tenant_id

      for %{id: id, stored: stored} <- seeded do
        payload = items[id]["payload"]
        # every top-level key of the stored payload whose value is A's id (either case) survives
        for {key, value} <- stored, is_binary(value), String.downcase(value) == own do
          assert payload[key] == value, "#{key} of #{id} was dropped"
        end
      end
    end

    test "other_payload_fields_and_envelope_unchanged", ctx do
      seeded = seed!(ctx.a, ctx.b)
      shaped = ctx.a |> get_events(["TENANT_ADMIN"]) |> decode_items()

      # baseline: the same schema read UNSHAPED (A pinned as THE platform tenant)
      Fixture.pin!(ctx.a.tenant_id)
      raw_resp = get_events(ctx.a, ["PLATFORM_ADMIN"])
      raw = decode_items(raw_resp)
      Fixture.pin!(ctx.p.tenant_id)

      assert length(shaped) == length(seeded)
      assert length(raw) == length(seeded)
      assert Enum.map(shaped, & &1["event_id"]) == Enum.map(seeded, & &1.id)

      for {s, r, e} <- Enum.zip([shaped, raw, seeded]) do
        # envelope equal to the unshaped read, key set unchanged
        # (the non-operator item has no actor_id; the unshaped read still does)
        assert Map.delete(s, "payload") == r |> Map.delete("payload") |> Map.delete("actor_id")
        refute Map.has_key?(s, "actor_id")
        assert Map.has_key?(r, "actor_id")

        assert s |> Map.keys() |> Enum.sort() ==
                 ["event_id", "event_type", "payload", "sequence_num", "timestamp"]

        assert s["event_type"] == e.type
        # the unshaped payload is exactly what was stored; the shaped one exactly the expectation
        assert r["payload"] == e.stored
        assert s["payload"] == e.shaped
      end

      body = Jason.decode!(get_events(ctx.a, ["TENANT_ADMIN"]).resp_body)
      assert body |> Map.keys() |> Enum.sort() == ["items", "next_cursor"]
    end

    test "pin_unset_would_be_operator_is_shaped_like_everyone_else", ctx do
      seeded = seed!(ctx.p, ctx.b)
      Fixture.unpin!()

      # REQ-447 PR 2: with no pin there is no platform tenant, so a PLATFORM_ADMIN holds nothing
      # anywhere (403, no event data); the tenant's own TENANT_ADMIN is shaped like everyone else.
      denied = get_events(ctx.p, ["PLATFORM_ADMIN"])
      assert denied.status == 403
      refute denied.resp_body =~ ctx.b.tenant_id

      resp = get_events(ctx.p, ["TENANT_ADMIN"])
      refute resp.resp_body =~ ctx.b.tenant_id
      refute resp.resp_body =~ "actor_id"

      items = resp |> decode_items() |> by_id()
      for e <- seeded, do: assert(items[e.id]["payload"] == e.shaped)
    end

    test "unknown_type_payload_is_empty_even_with_nested_own_tenant_id", ctx do
      [_, _, _, _, _, _, _, _, e8] = seed!(ctx.a, ctx.b)
      items = ctx.a |> get_events(["TENANT_ADMIN"]) |> decode_items() |> by_id()

      assert items[e8.id]["event_type"] == e8.type
      # e8 stores A's own id inside a nested list; the allowlist does not descend
      assert items[e8.id]["payload"] == %{}
    end

    test "other_roles_still_forbidden_and_see_no_event_data", ctx do
      seeded = seed!(ctx.a, ctx.b)

      for roles <- [["PROCESS_DESIGNER"], ["TASK_WORKER"], ["CANDIDATE"], ["AGENT_RUNNER"]] do
        resp = get_events(ctx.a, roles)
        assert resp.status == 403, "#{inspect(roles)}: #{resp.status}"
        refute resp.resp_body =~ ctx.b.tenant_id
        for e <- seeded, do: refute(resp.resp_body =~ e.id)
      end
    end
  end

  describe "operator" do
    test "operator_sees_every_tenant_id", ctx do
      seeded = seed!(ctx.p, ctx.b)

      resp = get_events(ctx.p, ["PLATFORM_ADMIN"])
      assert resp.status == 200
      assert resp.resp_body =~ ctx.b.tenant_id
      assert resp.resp_body =~ ctx.p.tenant_id

      items = resp |> decode_items() |> by_id()
      for e <- seeded, do: assert(items[e.id]["payload"] == e.stored)
      for {_id, item} <- items, do: assert(is_binary(item["actor_id"]))
    end
  end

  describe "allowlist" do
    defp promoted_attrs(ctx, extra) do
      Map.merge(
        %{
          event_type: "DEFINITION_PROMOTED",
          actor_id: Ecto.UUID.generate(),
          review_id: Ecto.UUID.generate(),
          source_tenant_id: ctx.b.tenant_id,
          target_tenant_id: ctx.a.tenant_id,
          source_definition_id: Ecto.UUID.generate(),
          target_definition_id: Ecto.UUID.generate(),
          process_key: Scope.unique_key("pk")
        },
        extra
      )
    end

    test "unlisted_tenant_keys_never_reach_a_non_operator", ctx do
      b = ctx.b.tenant_id

      attrs =
        promoted_attrs(ctx, %{tenant_ids: [b], tenantId: b, source_tenant: b, x_tenant_id: b})

      assert {:ok, %{event_id: id}} =
               PlatformEvents.append_definition_promoted(attrs, ctx.a.schema_name)

      resp = get_events(ctx.a, ["TENANT_ADMIN"])
      item = resp |> decode_items() |> by_id() |> Map.fetch!(id)

      assert item["payload"] |> Map.keys() |> Enum.sort() ==
               ["process_key", "target_definition_id", "target_tenant_id"]

      assert item["payload"]["target_tenant_id"] == ctx.a.tenant_id
      refute resp.resp_body =~ b
      refute resp.resp_body =~ String.upcase(b)
    end

    test "unknown_event_type_payload_is_empty_and_event_kept", ctx do
      seeded = seed!(ctx.a, ctx.b)
      e6 = Enum.at(seeded, 6)

      shaped_all = ctx.a |> get_events(["TENANT_ADMIN"]) |> decode_items()
      shaped_page = Jason.decode!(get_events(ctx.a, ["TENANT_ADMIN"], "page_size=2").resp_body)

      item = shaped_all |> by_id() |> Map.fetch!(e6.id)
      assert item["event_type"] == e6.type
      assert item["payload"] == %{}

      # the same schema read UNSHAPED (A pinned as the platform tenant), pin restored after
      Fixture.pin!(ctx.a.tenant_id)
      raw_all = ctx.a |> get_events(["PLATFORM_ADMIN"]) |> decode_items()
      raw_page = Jason.decode!(get_events(ctx.a, ["PLATFORM_ADMIN"], "page_size=2").resp_body)
      Fixture.pin!(ctx.p.tenant_id)

      assert Enum.map(shaped_all, & &1["event_id"]) == Enum.map(raw_all, & &1["event_id"])
      assert length(shaped_page["items"]) == length(raw_page["items"])
      assert shaped_page["next_cursor"] == nil == (raw_page["next_cursor"] == nil)
      assert shaped_page["next_cursor"] != nil
    end

    test "value_under_allowlisted_key_must_be_scalar", ctx do
      b = ctx.b.tenant_id

      # The shipped schema types process_key as a string, so the append would be rejected. A tenant
      # may register its own (higher) schema version of the type (Registry.get_type/2 picks the
      # highest), which models a producer writing a non-scalar value under an allowlisted key.
      assert {:ok, _} =
               Letflow.EventStore.Registry.register_type(
                 %{
                   "name" => "DEFINITION_PROMOTED",
                   "schema_version" => 99,
                   "json_schema" => %{"type" => "object"},
                   "description" => "ISS-0999 non-scalar fixture"
                 },
                 ctx.a.tenant_id
               )

      attrs = promoted_attrs(ctx, %{process_key: %{"nested" => b}})

      assert {:ok, %{event_id: id}} =
               PlatformEvents.append_definition_promoted(attrs, ctx.a.schema_name)

      resp = get_events(ctx.a, ["TENANT_ADMIN"])
      item = resp |> decode_items() |> by_id() |> Map.fetch!(id)

      refute Map.has_key?(item["payload"], "process_key")
      assert Map.has_key?(item["payload"], "target_definition_id")
      refute resp.resp_body =~ b
    end

    test "non_operator_item_has_no_actor_id", ctx do
      seed!(ctx.a, ctx.b)
      items = ctx.a |> get_events(["TENANT_ADMIN"]) |> decode_items()

      assert length(items) == 9
      for item <- items, do: assert(Map.has_key?(item, "actor_id") == false)
    end
  end

  describe "pagination" do
    # "PE:<mint_time_us>:<seq>:<event_id>" -> the seek key "<seq>:<event_id>"
    defp seek_key(cursor) do
      assert {:ok, %Pagination.Cursor{inner: inner}} = Pagination.decode_cursor(cursor, "PE:", 3)
      ["PE", _mint, seq, event_id] = String.split(inner, ":", parts: 4)
      {String.to_integer(seq), event_id}
    end

    defp walk(fixture, query_prefix, roles) do
      Stream.unfold({:first, nil}, fn
        :done ->
          nil

        {:first, nil} ->
          page(fixture, query_prefix, roles, nil)

        {:next, cursor} ->
          page(fixture, query_prefix, roles, cursor)
      end)
      |> Enum.to_list()
    end

    defp page(fixture, query_prefix, roles, cursor) do
      query =
        if cursor,
          do: query_prefix <> "&cursor=" <> URI.encode_www_form(cursor),
          else: query_prefix

      body =
        fixture |> get_events(roles, query) |> then(&Jason.decode!(&1.resp_body))

      next = if body["next_cursor"], do: {:next, body["next_cursor"]}, else: :done
      {body, next}
    end

    test "pagination_is_unaffected", ctx do
      seeded = seed!(ctx.a, ctx.b)
      seeded_ids = Enum.map(seeded, & &1.id)

      # shaped (A is an ordinary tenant)
      pages = walk(ctx.a, "page_size=2", ["TENANT_ADMIN"])
      ids = for p <- pages, i <- p["items"], do: i["event_id"]
      assert ids == seeded_ids
      assert pages |> List.last() |> Map.fetch!("next_cursor") == nil
      assert length(pages) == 5

      # each non-last page's cursor decodes to the seek key (sequence_num, event_id) of the
      # page's last item (cursor STRINGS are never compared: each embeds a mint time)
      for p <- Enum.drop(pages, -1) do
        last = List.last(p["items"])
        assert seek_key(p["next_cursor"]) == {last["sequence_num"], last["event_id"]}
      end

      # unshaped read of the same schema (A pinned as THE platform tenant): same paging
      Fixture.pin!(ctx.a.tenant_id)
      raw_pages = walk(ctx.a, "page_size=2", ["PLATFORM_ADMIN"])
      Fixture.pin!(ctx.p.tenant_id)

      assert for(p <- raw_pages, do: Enum.map(p["items"], & &1["event_id"])) ==
               for(p <- pages, do: Enum.map(p["items"], & &1["event_id"]))

      assert for(p <- raw_pages, p["next_cursor"], do: seek_key(p["next_cursor"])) ==
               for(p <- pages, p["next_cursor"], do: seek_key(p["next_cursor"]))

      # the event_type filter narrows exactly as before
      filtered =
        ctx.a
        |> get_events(["TENANT_ADMIN"], "event_type=DEFINITION_PROMOTED")
        |> decode_items()

      assert Enum.map(filtered, & &1["event_id"]) ==
               Enum.map(Enum.take(seeded, 3) |> then(&[hd(&1), Enum.at(&1, 2)]), & &1.id)

      assert Enum.all?(filtered, &(&1["event_type"] == "DEFINITION_PROMOTED"))
    end
  end
end
