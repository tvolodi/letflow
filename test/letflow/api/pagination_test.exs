defmodule Letflow.Api.PaginationTest do
  @moduledoc """
  Tests for `Letflow.Api.Pagination` (REQ-067, spec: `test/specs/REQ-067.md`).

  Pure unit tests — `Letflow.Api.Pagination` has no `Plug.Conn` and no
  `Ecto.Repo` dependency, so plain `ExUnit.Case` is used, matching
  `test/letflow/api/response_test.exs`'s precedent for DB-free surface.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Pagination
  alias Letflow.Api.Pagination.Cursor

  # ── AC1: constants, asserted via accessor, not a duplicated literal ────────

  describe "constants" do
    test "max_page_size/0 returns 200" do
      assert Pagination.max_page_size() == 200
    end

    test "default_page_size/0 returns 50" do
      assert Pagination.default_page_size() == 50
    end

    test "min_page_size/0 returns 1" do
      assert Pagination.min_page_size() == 1
    end

    test "cursor_expiry_us/0 returns 86_400_000_000" do
      assert Pagination.cursor_expiry_us() == 86_400_000_000
    end
  end

  # ── AC2: page-size validation, reject not clamp ────────────────────────────

  describe "parse_page_size_param/1" do
    test "nil is {:ok, nil}" do
      assert Pagination.parse_page_size_param(nil) == {:ok, nil}
    end

    test "an ordinary numeric string parses" do
      assert Pagination.parse_page_size_param("50") == {:ok, 50}
    end

    test "a non-numeric string is rejected" do
      assert Pagination.parse_page_size_param("abc") == {:error, :invalid_page_size}
    end

    test "trailing garbage after digits is rejected" do
      assert Pagination.parse_page_size_param("20x") == {:error, :invalid_page_size}
    end

    test "a decimal point is rejected" do
      assert Pagination.parse_page_size_param("3.5") == {:error, :invalid_page_size}
    end

    test "a negative sign is rejected" do
      assert Pagination.parse_page_size_param("-5") == {:error, :invalid_page_size}
    end
  end

  describe "validate_page_size/1" do
    test "nil defaults to 50" do
      assert Pagination.validate_page_size(nil) == {:ok, 50}
    end

    test "0 is rejected (below MIN_PAGE_SIZE)" do
      assert Pagination.validate_page_size(0) == {:error, :page_size_too_large}
    end

    test "201 is rejected (above MAX_PAGE_SIZE)" do
      assert Pagination.validate_page_size(201) == {:error, :page_size_too_large}
    end

    test "1 (MIN_PAGE_SIZE boundary) succeeds" do
      assert Pagination.validate_page_size(1) == {:ok, 1}
    end

    test "200 (MAX_PAGE_SIZE boundary) succeeds -- proves reject, not clamp" do
      # A clamp implementation (min(size, 200)) would make 201 above return
      # {:ok, 200} instead of an error; pinning both fences here.
      assert Pagination.validate_page_size(200) == {:ok, 200}
    end
  end

  # ── AC3: cross-endpoint prefix rejection ───────────────────────────────────

  describe "decode_cursor/4 and prefix validation (AC3)" do
    test "rejects a cursor minted with a different prefix" do
      raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "task-1")
      encoded = Pagination.encode_cursor(raw)

      assert Pagination.decode_cursor(encoded, "I:", 2) == {:error, :wrong_endpoint}
    end

    test "accepts the same cursor decoded with its own prefix" do
      raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "task-1")
      encoded = Pagination.encode_cursor(raw)

      assert {:ok, %Cursor{inner: ^raw}} = Pagination.decode_cursor(encoded, "T:", 2)
    end

    test "rejects a decoded payload shorter than the prefix" do
      encoded = Pagination.encode_cursor("x")

      assert Pagination.decode_cursor(encoded, "PREFIX:", 0) == {:error, :wrong_endpoint}
    end
  end

  # ── AC4: expiry checking, no wall-clock waiting ────────────────────────────

  describe "decode_cursor/4 and expiry (AC4)" do
    test "rejects a cursor built with a deliberately old timestamp" do
      # Fixed at the Unix epoch -- unconditionally more than 24h in the past
      # relative to any real clock read, with no sleep or clock manipulation.
      raw = Pagination.build_raw_cursor("T:", 0, "task-1")
      encoded = Pagination.encode_cursor(raw)

      assert Pagination.decode_cursor(encoded, "T:", 2) == {:error, :expired}
    end

    test "accepts a cursor built with the current timestamp" do
      raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "task-1")
      encoded = Pagination.encode_cursor(raw)

      assert {:ok, %Cursor{}} = Pagination.decode_cursor(encoded, "T:", 2)
    end

    test "honours a custom expiry_window_us narrower than the default" do
      five_seconds_ago = System.system_time(:microsecond) - 5_000_000
      raw = Pagination.build_raw_cursor("T:", five_seconds_ago, "task-1")
      encoded = Pagination.encode_cursor(raw)

      # 1s window, but the cursor is ~5s old: proves the 4th argument is
      # genuinely read, not silently overridden by the 24h default.
      assert Pagination.decode_cursor(encoded, "T:", 2, 1_000_000) == {:error, :expired}
    end
  end

  # ── AC5 / INV-1: tenant isolation is structural, not conventional ──────────

  describe "Cursor struct and tenant isolation (AC5, security-load-bearing)" do
    test "Cursor's struct fields are exactly [:inner]" do
      fields = %Cursor{} |> Map.from_struct() |> Map.keys()

      assert fields == [:inner]
    end

    # Fixture-only: NOT application code. Stands in for "this endpoint's own
    # request-context scoping" (REQ-072, not yet implemented). The cursor
    # itself carries no tenant field for this lookup to (correctly or
    # incorrectly) honour -- tenant_scope is supplied independently.
    defp fixture_rows do
      [
        %{tenant: :tenant_a, id: "a-1", name: "alpha-one"},
        %{tenant: :tenant_a, id: "a-2", name: "alpha-two"},
        %{tenant: :tenant_b, id: "b-1", name: "bravo-one"},
        %{tenant: :tenant_b, id: "b-2", name: "bravo-two"}
      ]
    end

    defp fixture_list(tenant_scope, %Cursor{inner: inner}) do
      # This "endpoint" only ever knows how to filter by the tenant_scope it
      # was independently called with -- it has no code path that could pull
      # a tenant out of `inner`, because `inner` never contains one (it is
      # "<prefix><timestamp>:<key>", built entirely from a row id).
      _ = inner

      fixture_rows()
      |> Enum.filter(&(&1.tenant == tenant_scope))
    end

    test "a cursor minted from tenant A's data cannot surface tenant A's rows when replayed scoped to tenant B" do
      # Mint the cursor while "iterating" tenant A -- its key is one of
      # tenant A's own row ids.
      raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "a-1")
      encoded = Pagination.encode_cursor(raw)

      # decode_cursor/4 succeeds regardless of which tenant "produced" the
      # cursor -- it has no tenant concept at all.
      assert {:ok, %Cursor{} = cursor} = Pagination.decode_cursor(encoded, "T:", 2)

      # Replay against a request scoped to tenant B.
      tenant_b_rows = fixture_list(:tenant_b, cursor)

      assert Enum.all?(tenant_b_rows, &(&1.tenant == :tenant_b))
      refute Enum.any?(tenant_b_rows, &(&1.tenant == :tenant_a))
      assert tenant_b_rows == [
               %{tenant: :tenant_b, id: "b-1", name: "bravo-one"},
               %{tenant: :tenant_b, id: "b-2", name: "bravo-two"}
             ]

      # And, so this isn't vacuous: the same cursor replayed scoped to
      # tenant A really does return tenant A's own rows -- the fixture lookup
      # genuinely works, it just never consulted the cursor for scope.
      tenant_a_rows = fixture_list(:tenant_a, cursor)
      assert Enum.all?(tenant_a_rows, &(&1.tenant == :tenant_a))
    end
  end

  # ── AC6: pagination completeness across 3+ pages ───────────────────────────

  describe "pagination completeness (AC6)" do
    defp fixture_all_items, do: for(i <- 1..25, do: %{sort_key: i, id: "item-#{i}"})

    # Rounds trip the cursor between pages through the module's own
    # encode/decode/build/parse functions, rather than passing the raw sort
    # key between pages directly -- so the module under test is actually
    # exercised, not just this fixture's bookkeeping.
    defp fixture_page(items, page_size, cursor) do
      after_key =
        case cursor do
          nil ->
            0

          %Cursor{inner: inner} ->
            # The prefix "T:" itself contains a colon (the 1st), so the
            # timestamp/key separator is the 2nd colon in the payload.
            colon = Pagination.find_nth_colon(inner, 2)
            {:ok, key} = Pagination.parse_int_from_cursor(inner, colon + 1, byte_size(inner) - colon - 1)
            key
        end

      page_items =
        items
        |> Enum.filter(&(&1.sort_key > after_key))
        |> Enum.sort_by(& &1.sort_key)
        |> Enum.take(page_size)

      next_cursor =
        if length(page_items) < page_size do
          nil
        else
          last = List.last(page_items)
          # The timestamp component is the current time (this fixture cares
          # about the sort key carried after the colon, not expiry); a fixed
          # past literal here would be rejected as expired by decode_cursor/4.
          raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "#{last.sort_key}")
          encoded = Pagination.encode_cursor(raw)
          {:ok, decoded} = Pagination.decode_cursor(encoded, "T:", 2)
          decoded
        end

      {page_items, next_cursor}
    end

    test "paging through 3+ pages returns every row exactly once, no dup, no gap" do
      items = fixture_all_items()

      {page1, cursor1} = fixture_page(items, 10, nil)
      {page2, cursor2} = fixture_page(items, 10, cursor1)
      {page3, cursor3} = fixture_page(items, 10, cursor2)

      assert length(page1) == 10
      assert length(page2) == 10
      assert length(page3) == 5
      assert cursor3 == nil

      all_ids = Enum.map(page1 ++ page2 ++ page3, & &1.id)

      assert length(all_ids) == 25
      assert Enum.uniq(all_ids) == all_ids
      assert Enum.sort(all_ids) == Enum.sort(Enum.map(items, & &1.id))
    end

    test "the final page reports no next_cursor" do
      items = fixture_all_items()

      {_page1, cursor1} = fixture_page(items, 10, nil)
      {_page2, cursor2} = fixture_page(items, 10, cursor1)
      {_page3, cursor3} = fixture_page(items, 10, cursor2)

      refute cursor1 == nil
      refute cursor2 == nil
      assert cursor3 == nil
    end
  end

  # ── round-trip and decode edge cases (design §4/§5) ────────────────────────

  describe "encode_cursor/1 and decode_cursor/4 round trip" do
    test "round-trip preserves inner exactly" do
      # A current timestamp, not the fixed literal used by the exact-format
      # case below -- this case is about round-trip fidelity, not the format
      # string, and a fixed past literal would (correctly) be rejected as
      # expired by decode_cursor/4's default expiry window.
      raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "abc123")

      assert {:ok, %Cursor{inner: ^raw}} =
               raw |> Pagination.encode_cursor() |> Pagination.decode_cursor("T:", 2)
    end

    test "rejects invalid base64" do
      assert Pagination.decode_cursor("not valid base64!!", "T:", 2) == {:error, :invalid_base64}
    end

    test "rejects a cursor with a malformed timestamp slice" do
      raw = "T:abc:key1"
      encoded = Pagination.encode_cursor(raw)

      assert Pagination.decode_cursor(encoded, "T:", 2) == {:error, :invalid_cursor}
    end

    test "rejects when expiry_ts_offset is past the end of the decoded payload" do
      raw = "T:1"
      encoded = Pagination.encode_cursor(raw)

      assert Pagination.decode_cursor(encoded, "T:", 100) == {:error, :invalid_cursor}
    end
  end

  # ── parse_int_from_cursor/3 and find_nth_colon/2 ───────────────────────────

  describe "parse_int_from_cursor/3" do
    test "extracts an in-bounds integer" do
      decoded = "T:12345:key1"

      assert Pagination.parse_int_from_cursor(decoded, 2, 5) == {:ok, 12345}
    end

    test "rejects an out-of-bounds offset/len" do
      decoded = "T:123"

      assert Pagination.parse_int_from_cursor(decoded, 2, 100) == {:error, :invalid_cursor}
    end

    test "rejects a non-digit slice" do
      decoded = "T:abcde"

      assert Pagination.parse_int_from_cursor(decoded, 2, 5) == {:error, :invalid_cursor}
    end
  end

  describe "find_nth_colon/2" do
    test "finds the n-th colon, 1-indexed" do
      slice = "a:bb:ccc:d"

      assert Pagination.find_nth_colon(slice, 1) == 1
      assert Pagination.find_nth_colon(slice, 2) == 4
      assert Pagination.find_nth_colon(slice, 3) == 8
    end

    test "returns nil when fewer than n colons exist" do
      slice = "a:bb:ccc"

      assert Pagination.find_nth_colon(slice, 5) == nil
    end
  end

  # ── build_raw_cursor/3 and build_raw_cursor_timestamp_key/4 exact format ──

  describe "raw cursor builders" do
    test ~s(build_raw_cursor produces "<prefix><timestamp_us>:<key>") do
      assert Pagination.build_raw_cursor("T:", 1_716_412_800_000_000, "abc123") ==
               "T:1716412800000000:abc123"
    end

    test ~s(build_raw_cursor_timestamp_key produces "<prefix><ts>:<key>:<created_at>") do
      assert Pagination.build_raw_cursor_timestamp_key(
               "I:",
               1_716_412_800_000_000,
               "abc123",
               1_716_412_860_000_000
             ) == "I:1716412800000000:abc123:1716412860000000"
    end
  end

  # ── page_response/2 ─────────────────────────────────────────────────────────

  describe "page_response/2" do
    test "count is always length(items), independent of caller input" do
      page = Pagination.page_response(["a", "b", "c"], "next-cursor-token")

      assert page.items == ["a", "b", "c"]
      assert page.count == 3
      assert page.next_cursor == "next-cursor-token"
    end

    test "count is 0 for an empty item list, next_cursor nil" do
      page = Pagination.page_response([], nil)

      assert page.count == 0
      assert page.next_cursor == nil
    end
  end
end
