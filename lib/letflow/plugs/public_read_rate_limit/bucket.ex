defmodule Letflow.Plugs.PublicReadRateLimit.Bucket do
  @moduledoc """
  The ETS-backed token bucket behind `Letflow.Plugs.PublicReadRateLimit`
  (REQ-352, design §11.3). Owns one named, public ETS table,
  `:letflow_public_read_rate_limit`, mirroring the visibility/concurrency
  shape `Letflow.Metrics.Registry` already established for its own table --
  `consume/3` is called directly from the calling (request) process via
  plain `:ets` calls, never a `GenServer.call/2` round-trip; this
  `GenServer` exists solely to own the table's lifetime under supervision.

  ## Algorithm (lazy-refill token bucket, no background timer)

  `consume/3` reads the current row (a missing key is treated as a full
  bucket at `capacity`), refills proportionally to elapsed wall time, then
  either decrements by one token and writes the result (`:ok`) or leaves the
  row unchanged and returns `:rate_limited`.

  This is a check-then-write over two separate `:ets` calls
  (`:ets.lookup/2` then `:ets.insert/2`), **not** `:ets.update_counter/4` --
  the refill computation depends on elapsed wall time, so it is not a pure
  integer increment. A small race under concurrent requests for the SAME key
  can let slightly more than `capacity` tokens through in a burst -- an
  accepted imprecision for a best-effort limiter (not a security boundary;
  no case in the resolution refusal table depends on the limiter being
  exact) and must not be "fixed" with a lock that would serialize this
  route class's hot path.
  """

  use GenServer

  @table :letflow_public_read_rate_limit

  @type bucket_key :: :global | {:ip, :inet.ip_address()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    {:ok, %{}}
  end

  @doc """
  Attempts to consume one token from `key`'s bucket (capacity `capacity`,
  refilling at `refill_per_sec` tokens/second). `:ok` on success,
  `:rate_limited` when the bucket has no tokens available.
  """
  @spec consume(bucket_key(), capacity :: pos_integer(), refill_per_sec :: number()) ::
          :ok | :rate_limited
  def consume(key, capacity, refill_per_sec) do
    now_ms = System.monotonic_time(:millisecond)

    {tokens, last_refill_ms} =
      case :ets.lookup(@table, key) do
        [{^key, tokens, last_refill_ms}] -> {tokens, last_refill_ms}
        [] -> {capacity * 1.0, now_ms}
      end

    elapsed_ms = now_ms - last_refill_ms
    refilled = min(capacity * 1.0, tokens + elapsed_ms / 1000 * refill_per_sec)

    if refilled < 1 do
      :rate_limited
    else
      :ets.insert(@table, {key, refilled - 1, now_ms})
      :ok
    end
  end
end
