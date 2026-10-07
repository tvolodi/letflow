defmodule Letflow.Test.LoggerCollectorTest do
  @moduledoc """
  ISS-1038 / Q-1039 (spec `test/specs/ISS-1038.md`): the flake class "a test asserts over a
  GLOBAL `capture_log` and sees an unrelated test's event".

  Observed in CI: `no leak: untrusted_implicit` failed because its capture held an
  error-level `alert delivery exhausted` event logged by ANOTHER test's alert deliverer
  (`component: "alert_delivery"`). The tests below reproduce that deterministically inside
  one window (message-synchronised, no sleeps): an own event from a `Task.Supervisor` child
  and an unrelated event from a plain spawned process. The old `capture_log` style contains
  both; the attributed `LoggerCollector` contains only the own one.

  `async: false`: the handler touches the VM-global primary translator filter.
  """

  use ExUnit.Case, async: false

  require Logger

  import ExUnit.CaptureLog

  alias Letflow.Test.LoggerCollector

  @own "own event from a supervised child"
  @unrelated "alert delivery exhausted"

  # Runs, inside the caller's window: an own event from a Task.Supervisor child of the test
  # process, then (provably inside the window, by message) an unrelated event from a plain
  # process with no caller link, logged exactly like lib/letflow/obs/alerts.ex does.
  defp inject(sup) do
    Task.Supervisor.async_nolink(sup, fn -> Logger.error(@own) end) |> Task.await()

    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :go -> :ok
        end

        Logger.error(@unrelated, component: "alert_delivery", attempts: 3)
        send(parent, :unrelated_logged)
      end)

    send(pid, :go)
    assert_receive :unrelated_logged, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    :ok
  end

  setup do
    %{sup: start_supervised!(Task.Supervisor)}
  end

  test "attributed collector: the own event is present, the unrelated one is not", %{sup: sup} do
    collector = LoggerCollector.attach!(attribute_to: self(), sasl: false, raw: false)
    inject(sup)
    LoggerCollector.assert_alive!(collector)
    LoggerCollector.detach(collector)

    entries = LoggerCollector.collected(collector)

    assert [%{level: :error, text: @own}] = entries
    # the very assertion that flaked: no error-level event other than the code under test's own
    refute Enum.any?(entries, &(&1.text =~ @unrelated))
  end

  test "the OLD capture_log style DOES contain the unrelated line (the observed flake)", %{
    sup: sup
  } do
    log = capture_log([level: :error], fn -> inject(sup) end)

    assert log =~ @own
    # A `refute log =~ "alert delivery exhausted"` / `errors == []` over this capture fails.
    assert log =~ @unrelated
  end

  test "attribute_to: nil collects both events", %{sup: sup} do
    collector = LoggerCollector.attach!(sasl: false, raw: false)
    inject(sup)
    LoggerCollector.detach(collector)

    texts = collector |> LoggerCollector.collected() |> Enum.map(& &1.text)
    assert @own in texts
    assert @unrelated in texts
  end

  test "also_from picks up an event emitted by a registered process, and only when listed" do
    name = :"logger_collector_test_emitter_#{System.unique_integer([:positive])}"
    parent = self()

    pid =
      spawn_link(fn ->
        Process.register(self(), name)
        send(parent, :registered)

        receive do
          :go -> Logger.error("emitted by the registered process")
        end

        send(parent, :emitted)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered, 5_000

    without = LoggerCollector.attach!(attribute_to: self(), sasl: false, raw: false)

    with_name =
      LoggerCollector.attach!(
        attribute_to: self(),
        sasl: false,
        raw: false,
        also_from: [name]
      )

    send(pid, :go)
    assert_receive :emitted, 5_000
    send(pid, :stop)

    LoggerCollector.detach(with_name)
    LoggerCollector.detach(without)

    assert [%{text: "emitted by the registered process"}] = LoggerCollector.collected(with_name)
    assert [] = LoggerCollector.collected(without)
  end

  test "default options keep the REQ-441 contract: SASL forced on, text = message + raw term" do
    before_filter = translator_filter()

    collector = LoggerCollector.attach!()

    assert {:logger_translator, {_fun, %{sasl: true}}} = translator_filter()

    Logger.error("default-contract-line")
    LoggerCollector.assert_alive!(collector)
    LoggerCollector.detach(collector)

    assert translator_filter() == before_filter

    assert [%{level: :error, text: text}] =
             collector
             |> LoggerCollector.collected()
             |> Enum.filter(&(&1.text =~ "default-contract-line"))

    [formatted, raw] = String.split(text, "\n", parts: 2)
    assert formatted == "default-contract-line"
    assert raw =~ "level: :error"
    assert raw =~ "meta:"
  end

  test "sasl: false leaves the translator filter untouched; raw: false yields the bare message" do
    before_filter = translator_filter()

    collector = LoggerCollector.attach!(sasl: false, raw: false)
    assert translator_filter() == before_filter

    Logger.error("bare-message-line")
    LoggerCollector.detach(collector)

    assert translator_filter() == before_filter

    assert [%{text: "bare-message-line"}] =
             collector |> LoggerCollector.collected() |> Enum.filter(&(&1.text =~ "bare-message"))
  end

  test "assert_alive!/1 fails loudly when the handler was removed" do
    collector = LoggerCollector.attach!(sasl: false)
    assert :ok = LoggerCollector.assert_alive!(collector)

    {id, _ref, _original} = collector
    :ok = :logger.remove_handler(id)

    assert_raise RuntimeError, ~r/was removed/, fn -> LoggerCollector.assert_alive!(collector) end
    LoggerCollector.detach(collector)
  end

  defp translator_filter do
    :logger.get_primary_config().filters |> List.keyfind(:logger_translator, 0)
  end
end
