defmodule Letflow.Plugs.LoginDiscoveryRateLimit.Bucket do
  @moduledoc """
  The ETS-backed token bucket behind `Letflow.Plugs.LoginDiscoveryRateLimit`
  (REQ-436, design `req436-login-discovery-rate-limiter.md`). Owns ONE named,
  public ETS table, `:letflow_login_discovery_rate_limit`, entirely separate
  from `Letflow.Plugs.PublicReadRateLimit.Bucket`'s table: no key, bucket or
  counter is shared with `/api/public`. Every key written here is a tuple
  whose first element is `:login_discovery`.

  The token-bucket algorithm is the same lazy-refill idea as
  `Letflow.Plugs.PublicReadRateLimit.Bucket` (see its moduledoc), restated
  here with integer micro-token state so `consume/4` can be a true
  compare-and-swap and the sweep guard can use the identical arithmetic.

  `consume/3,4` and `sweep/1,2` are plain `:ets` calls made from the calling
  process; this `GenServer` only owns the table and the periodic sweep clock.

  ## Row layout

  A bucket row is `{bucket_key, kind, tokens_u, last_ms}` where `tokens_u` is
  fixed-point micro-tokens (1 token = 1_000_000). Bookkeeping rows are
  3-tuples (`{{:login_discovery, :count, population}, :count, n}` and
  `{{:login_discovery, :inline_sweep, population}, :inline_sweep, last_ms}`).

  ## Bounded state

  Only lossless eviction: `sweep/2` deletes exactly the rows whose tokens have
  refilled to capacity (behaviourally identical to an absent row). Each new
  non-global key must first reserve a slot in its population's count row; at
  the cap an inline sweep runs and, if still full, the new key is refused
  (fail closed). A live key is never evicted.
  """

  use GenServer

  alias Letflow.Plugs.LoginDiscoveryRateLimit, as: Limiter

  @table :letflow_login_discovery_rate_limit
  @micro 1_000_000
  @max_cas_attempts 8

  @type ip_bucket_id ::
          {:v4, :inet.ip4_address()}
          | {:v6_64, {0..65535, 0..65535, 0..65535, 0..65535}}

  @type bucket_key ::
          {:login_discovery, :global}
          | {:login_discovery, :ip, ip_bucket_id()}
          | {:login_discovery, :email_hmac, binary()}
          | {:login_discovery, :email_send, binary()}

  @type population :: :ip | :email
  @type sweep_scope :: population() | :all

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok = Limiter.validate_config!(Application.get_env(:letflow, Limiter, []))

    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    interval = Limiter.config().sweep_interval_ms
    Process.send_after(self(), :sweep, interval)
    {:ok, %{sweep_interval_ms: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(System.monotonic_time(:millisecond))
    Process.send_after(self(), :sweep, Limiter.config().sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @spec table() :: :letflow_login_discovery_rate_limit
  def table, do: @table

  @doc """
  Attempts to consume one token from `key`'s bucket. `:ok` on success,
  `:rate_limited` when the bucket is empty, the population cap refuses a new
  key, or the bounded compare-and-swap retries are exhausted (fail closed).
  `now_ms` is the test seam for the clock.
  """
  @spec consume(bucket_key(), pos_integer(), number(), integer()) :: :ok | :rate_limited
  def consume(key, capacity, refill_per_sec, now_ms) do
    cap_u = capacity * @micro
    rate = rate_u_s(refill_per_sec)
    kind = kind_of(key)
    attempt(key, kind, cap_u, rate, now_ms, @max_cas_attempts)
  end

  @spec consume(bucket_key(), pos_integer(), number()) :: :ok | :rate_limited
  def consume(key, capacity, refill_per_sec) do
    consume(key, capacity, refill_per_sec, System.monotonic_time(:millisecond))
  end

  defp attempt(_key, _kind, _cap_u, _rate, _now, 0), do: :rate_limited

  defp attempt(key, kind, cap_u, rate, now_ms, left) do
    case :ets.lookup(@table, key) do
      [{^key, ^kind, tokens_u, last_ms} = row] ->
        refilled = refill(tokens_u, last_ms, now_ms, rate, cap_u)

        if refilled < @micro do
          :rate_limited
        else
          case cas(row, {key, kind, refilled - @micro, now_ms}) do
            1 -> :ok
            _ -> attempt(key, kind, cap_u, rate, now_ms, left - 1)
          end
        end

      [] ->
        insert_absent(key, kind, cap_u, rate, now_ms, left)
    end
  end

  defp insert_absent(key, :global, cap_u, rate, now_ms, left) do
    if :ets.insert_new(@table, {key, :global, cap_u - @micro, now_ms}) do
      :ok
    else
      attempt(key, :global, cap_u, rate, now_ms, left - 1)
    end
  end

  defp insert_absent(key, kind, cap_u, rate, now_ms, left) do
    pop = population_of(kind)

    case reserve_slot(pop, now_ms) do
      :refused ->
        :rate_limited

      :reserved ->
        if :ets.insert_new(@table, {key, kind, cap_u - @micro, now_ms}) do
          :ok
        else
          release(pop, 1)
          attempt(key, kind, cap_u, rate, now_ms, left - 1)
        end
    end
  end

  # Compare-and-swap: replaces the row only if it is still exactly `old`.
  # Returns 1 when replaced, 0 when anyone changed or deleted it first.
  defp cas(old, new), do: :ets.select_replace(@table, [{old, [], [{:const, new}]}])

  defp reserve_slot(pop, now_ms) do
    cap = cap_for(pop)

    if bump(pop) <= cap do
      :reserved
    else
      release(pop, 1)
      maybe_inline_sweep(pop, now_ms)

      if bump(pop) <= cap do
        :reserved
      else
        release(pop, 1)
        :refused
      end
    end
  end

  defp bump(pop) do
    k = count_key(pop)
    :ets.update_counter(@table, k, {3, 1}, {k, :count, 0})
  end

  defp release(pop, n) do
    k = count_key(pop)
    :ets.update_counter(@table, k, {3, -n}, {k, :count, 0})
    :ok
  end

  defp count_key(pop), do: {:login_discovery, :count, pop}

  defp cap_for(:ip), do: Limiter.config().max_ip_keys
  defp cap_for(:email), do: Limiter.config().max_email_keys

  # Throttled so a full population cannot become an O(n)-per-request amplifier.
  defp maybe_inline_sweep(pop, now_ms) do
    marker = {:login_discovery, :inline_sweep, pop}
    min_interval = Limiter.config().inline_sweep_min_interval_ms

    won? =
      case :ets.lookup(@table, marker) do
        [] ->
          :ets.insert_new(@table, {marker, :inline_sweep, now_ms})

        [{^marker, :inline_sweep, last} = old] ->
          now_ms - last >= min_interval and
            :ets.select_replace(@table, [
              {old, [], [{:const, {marker, :inline_sweep, now_ms}}]}
            ]) == 1
      end

    if won?, do: sweep(now_ms, pop)
    :ok
  end

  @doc """
  Deletes exactly the idle rows (tokens refilled to capacity) of `scope`,
  returning the number deleted. Never touches `:global` or a non-idle row.
  """
  @spec sweep(integer(), sweep_scope()) :: non_neg_integer()
  def sweep(now_ms, scope \\ :all)

  def sweep(now_ms, :all), do: sweep(now_ms, :ip) + sweep(now_ms, :email)
  def sweep(now_ms, :ip), do: sweep_kinds(now_ms, :ip, [:ip])
  def sweep(now_ms, :email), do: sweep_kinds(now_ms, :email, [:email_hmac, :email_send])

  defp sweep_kinds(now_ms, pop, kinds) do
    config = Limiter.config()

    deleted =
      Enum.sum(
        for kind <- kinds do
          {capacity, refill} = kind_params(kind, config)
          select_delete_idle(kind, now_ms, capacity * @micro, rate_u_s(refill))
        end
      )

    # Delete first, decrement second: the count only ever over-estimates.
    if deleted > 0, do: release(pop, deleted)
    deleted
  end

  defp select_delete_idle(kind, now_ms, cap_u, rate) do
    elapsed = {:-, now_ms, :"$3"}

    guard = [
      {:andalso, {:>=, elapsed, 0}, {:>=, {:+, :"$2", {:div, {:*, elapsed, rate}, 1000}}, cap_u}}
    ]

    :ets.select_delete(@table, [{{:"$1", kind, :"$2", :"$3"}, guard, [true]}])
  end

  @doc "Live-row count of a population (`:ip` or `:email`), O(1)."
  @spec size(population()) :: non_neg_integer()
  def size(pop) when pop in [:ip, :email] do
    case :ets.lookup(@table, count_key(pop)) do
      [{_, :count, n}] -> n
      [] -> 0
    end
  end

  @doc "Effective token count of `key` at `now_ms`, without consuming."
  @spec token_count(bucket_key(), integer()) :: {:ok, float()} | :absent
  def token_count(key, now_ms) do
    case :ets.lookup(@table, key) do
      [{^key, kind, tokens_u, last_ms}] ->
        {capacity, refill} = kind_params(kind, Limiter.config())
        {:ok, refill(tokens_u, last_ms, now_ms, rate_u_s(refill), capacity * @micro) / @micro}

      [] ->
        :absent
    end
  end

  defp refill(tokens_u, last_ms, now_ms, rate, cap_u) do
    elapsed = max(now_ms - last_ms, 0)
    min(cap_u, tokens_u + div(elapsed * rate, 1000))
  end

  defp rate_u_s(refill_per_sec), do: round(refill_per_sec * @micro)

  defp kind_of({:login_discovery, :global}), do: :global
  defp kind_of({:login_discovery, kind, _}), do: kind

  defp population_of(:ip), do: :ip
  defp population_of(:email_hmac), do: :email
  defp population_of(:email_send), do: :email

  defp kind_params(:global, c), do: {c.global_capacity, c.global_refill_per_sec}
  defp kind_params(:ip, c), do: {c.ip_capacity, c.ip_refill_per_sec}
  defp kind_params(:email_hmac, c), do: {c.email_capacity, c.email_refill_per_sec}
  defp kind_params(:email_send, c), do: {c.send_capacity, c.send_refill_per_sec}
end
