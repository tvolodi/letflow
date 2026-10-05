defmodule Letflow.Routers.LoginDiscoveryTimingTest do
  @moduledoc """
  REQ-437 (spec `test/specs/REQ-437.md`), design s10.3: the WALL-CLOCK sanity bound.

  Method: for each pair of input classes that must be indistinguishable, 200
  alternating paired requests (the order inside a pair flips every iteration, so a
  warm-up or GC drift cannot favour one class), each timed with `:timer.tc/1`
  around a full `Letflow.Router` call. Bound: the MEDIAN of the paired differences
  is below 25 ms in absolute value, and the sign is not one-sided with a material
  magnitude (all 200 differences on one side AND |median| > 5 ms would be a
  systematic skew).

  Pairs: Mode A known single vs unknown; Mode B multi-tenant vs unknown; Mode B
  uniform-tenant single vs unknown (the additional pair of the per-tenant AC). The
  Mode B 200 single match is excluded by design (it is disclosed).

  This test is NOT the binding timing guarantee (that is the structural query /
  submission count in `login_discovery_test.exs`); it is tagged `:timing` so it can
  be quarantined with `mix test --exclude timing` without weakening the structural
  test. `async: false`.
  """

  use Letflow.DataCase, async: false

  @moduletag :timing

  alias Letflow.Test.LoginDiscoveryHelpers, as: H

  @pairs 200
  @bound_ms 25

  setup_all do
    {:ok, world: H.provision_world!([:a, :b, :c])}
  end

  setup %{world: w} do
    H.setup_limiter!([])
    H.put_enabled!(true)
    H.set_mode!(w.a, "redirect_single")
    H.set_mode!(w.b, "redirect_single")
    H.set_mode!(w.c, "uniform_plus_email")
    Letflow.LoginDiscoveryNotifierDouble.reset()
    H.await_idle()
    :ok
  end

  defp seed(w, keys) do
    email = H.email()
    Enum.each(keys, &H.add_entry!(Map.fetch!(w, &1), email))
    email
  end

  defp time_ms(email) do
    {micros, conn} = :timer.tc(fn -> H.post_email(email) end)
    assert conn.status == 202
    micros / 1_000
  end

  # Alternating paired measurement; returns the list of (a - b) differences in ms.
  defp paired(email_a, email_b) do
    # warm-up: code paths, ETS, the connection
    for _ <- 1..10 do
      H.post_email(email_a)
      H.post_email(email_b)
    end

    H.await_idle()

    for i <- 1..@pairs do
      if rem(i, 2) == 0 do
        a = time_ms(email_a)
        b = time_ms(email_b)
        a - b
      else
        b = time_ms(email_b)
        a = time_ms(email_a)
        a - b
      end
    end
    |> tap(fn _ -> H.await_idle() end)
  end

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, div(n, 2)),
      else: (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
  end

  defp assert_indistinguishable(label, diffs) do
    assert length(diffs) == @pairs
    med = median(diffs)
    positive = Enum.count(diffs, &(&1 > 0))
    one_sided = positive in [0, @pairs]

    IO.puts(
      "[REQ-437 timing] #{label}: #{@pairs} alternating pairs, median diff #{Float.round(med, 3)} ms " <>
        "(bound #{@bound_ms} ms), #{positive}/#{@pairs} positive"
    )

    assert abs(med) < @bound_ms, "#{label}: median paired difference #{med} ms >= #{@bound_ms} ms"

    refute one_sided and abs(med) > 5,
           "#{label}: systematic skew (every difference on one side, median #{med} ms)"
  end

  test "Mode A (:uniform_plus_email): known single vs unknown", %{world: w} do
    H.put_mode!(:uniform_plus_email)
    known = seed(w, [:b])
    unknown = H.email()
    assert_indistinguishable("mode A known vs unknown", paired(known, unknown))
  end

  test "Mode B (:redirect_single): multi-tenant vs unknown", %{world: w} do
    H.put_mode!(:redirect_single)
    multi = seed(w, [:a, :b])
    unknown = H.email()
    assert_indistinguishable("mode B multi vs unknown", paired(multi, unknown))
  end

  test "Mode B (:redirect_single): single match in a uniform tenant vs unknown", %{world: w} do
    H.put_mode!(:redirect_single)
    uniform_single = seed(w, [:c])
    unknown = H.email()

    assert_indistinguishable(
      "mode B uniform-tenant single vs unknown",
      paired(uniform_single, unknown)
    )
  end
end
