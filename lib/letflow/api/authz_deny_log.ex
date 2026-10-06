defmodule Letflow.Api.AuthzDenyLog do
  @moduledoc """
  One attribution log line per authorization denial (ISS-0995).

  `Letflow.Plugs.Authorize` calls `log_denial/3` exactly once for every
  `:Deny403` decision, just before it sends the unchanged 403. The line lets an
  operator attribute a denial to a request, a caller and a tenant after the
  fact, without ever carrying anything INV-4 forbids.

  Design: `lib/letflow/design/iss0995-authz-deny-attribution-log.md`.

  ## Line shape

      authz_deny method=GET route=/api/v1/tenants/:slug policy=TenantsManage platform_scope=true caller_platform_tenant=false caller=3fa91c07be2d4a10 tenant=9b0c55e1a7d3f642

  plus `" suppressed=<n>"` when `n > 0` denials were withheld by sampling since
  the previous line for the same slot. The same facts are attached as logger
  metadata (`authz_method`, `authz_route`, `authz_policy`, `authz_platform_scope`,
  `authz_caller_platform_tenant`, `authz_caller`, `authz_tenant`, and
  `authz_suppressed` when `n > 0`), generated from the same map, so the message
  and the metadata cannot drift.

  ## INV-4: what can reach the line

  Only constants, an allow-listed HTTP method token, the compile-time route
  template (with the `forward` glob removed and printable-ASCII gated), an
  existing policy-key atom name (printable-ASCII gated), booleans, an integer
  count and two 16-hex keyed pseudonyms. The raw path, query string, params,
  body, headers, remote IP, token, email, raw user id and raw tenant id are
  never read. The caller's "tenant" is the caller's own database-resolved
  tenant (`auth_context.tenant_id`), never a value taken from the path or body.

  ## Hash key

  `subkey = HMAC-SHA256(master, "letflow/authz-deny-log/v1" <> <<1>>)` (HKDF-Expand,
  one block), where `master` is the already validated 32-byte
  `:secrets_master_key`. No new environment variable and no boot failure. An id
  is hashed as `HMAC-SHA256(subkey, "user:" <> id)` / `"tenant:" <> id`, rendered
  as the first 16 lowercase hex characters; a non-binary or empty id renders
  `"none"`. Hashes are stable only for the lifetime of the master key.

  ## Sampling

  At most one line per `{policy, caller hash, tenant hash}` slot per window
  (`:authz_deny_log_window_s`, default 60 seconds, `0` disables) using a pair of
  4096-slot `:atomics` arrays kept in `:persistent_term` (lazy, ownerless, no
  supervision change). Hash collisions share a slot's budget (accepted).

  ## Never raises

  `log_denial/3` always returns `:ok`. Any failure logs only a constant line
  (`authz_deny_log_failed class=... exception=...`), at most once per boot per
  class and exception module, carrying no value from the failed call.
  """

  require Logger

  alias Letflow.Api.Authorization

  @label "letflow/authz-deny-log/v1"
  @slots 4096
  @default_window 60
  @methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)
  @sampler_key {__MODULE__, :sampler}
  @fallback_key {__MODULE__, :fallback_key}
  @fallback_noted_key {__MODULE__, :fallback_noted}

  @type policy_key :: atom()
  @type hashed_id :: String.t()
  @type fields :: %{
          method: String.t(),
          route: String.t(),
          policy: String.t(),
          platform_scope: boolean(),
          caller_platform_tenant: boolean(),
          caller: hashed_id(),
          tenant: hashed_id()
        }

  @doc """
  Emits (subject to sampling) one attribution line for an authorization
  denial. Always returns `:ok`; never raises, exits or throws.
  """
  @spec log_denial(Plug.Conn.t(), Authorization.AccessContext.t(), policy_key()) :: :ok
  def log_denial(conn, ctx, policy_key) do
    do_log_denial(conn, ctx, policy_key)
  rescue
    e -> note_failure(:error, exception_module(e))
  catch
    kind, _reason -> note_failure(kind, nil)
  end

  defp do_log_denial(conn, ctx, policy_key) do
    sub = subkey()
    caller = hash_id(:user, ctx.user_id, sub)
    tenant = hash_id(:tenant, tenant_id(conn), sub)

    case sample(policy_key, caller, tenant) do
      :suppress ->
        :ok

      {:emit, n} ->
        f = fields_from(conn, ctx, policy_key, caller, tenant)
        Logger.warning(format_message(f, n), metadata(f, n))
        :ok
    end
  end

  @doc """
  Builds the sanitised `t:fields/0` map for a denial (hashes computed with the
  current sub-key). Exposed for tests.
  """
  @spec build_fields(Plug.Conn.t(), Authorization.AccessContext.t(), policy_key()) :: fields()
  def build_fields(conn, ctx, policy_key) do
    sub = subkey()

    fields_from(
      conn,
      ctx,
      policy_key,
      hash_id(:user, ctx.user_id, sub),
      hash_id(:tenant, tenant_id(conn), sub)
    )
  end

  defp fields_from(conn, ctx, policy_key, caller, tenant) do
    %{
      method: method_token(conn.method),
      route: route_pattern(conn),
      policy: policy_token(policy_key),
      platform_scope: platform_scope?(policy_key),
      caller_platform_tenant: ctx.platform_tenant? == true,
      caller: caller,
      tenant: tenant
    }
  end

  defp tenant_id(conn), do: Map.get(conn.assigns.auth_context, :tenant_id)

  @doc """
  Renders the fixed-grammar `key=value` message; `" suppressed=<n>"` is
  appended only when `n > 0`.
  """
  @spec format_message(fields(), non_neg_integer()) :: String.t()
  def format_message(f, n) do
    base =
      "authz_deny method=#{f.method} route=#{f.route} policy=#{f.policy}" <>
        " platform_scope=#{f.platform_scope}" <>
        " caller_platform_tenant=#{f.caller_platform_tenant}" <>
        " caller=#{f.caller} tenant=#{f.tenant}"

    if n > 0, do: base <> " suppressed=" <> Integer.to_string(n), else: base
  end

  @doc """
  Logger metadata carrying the same facts as `format_message/2`, in a fixed key
  order; `authz_suppressed` is present only when `n > 0`.
  """
  @spec metadata(fields(), non_neg_integer()) :: keyword()
  def metadata(f, n) do
    base = [
      authz_method: f.method,
      authz_route: f.route,
      authz_policy: f.policy,
      authz_platform_scope: f.platform_scope,
      authz_caller_platform_tenant: f.caller_platform_tenant,
      authz_caller: f.caller,
      authz_tenant: f.tenant
    ]

    if n > 0, do: base ++ [authz_suppressed: n], else: base
  end

  @doc """
  Keyed pseudonym of an id: first 16 lowercase hex chars of
  `HMAC-SHA256(subkey, "user:" | "tenant:" <> id)`; `"none"` for any
  non-binary or empty id. The id is never coerced.
  """
  @spec hash_id(:user | :tenant, term(), binary()) :: hashed_id()
  def hash_id(kind, id, subkey) when kind in [:user, :tenant] and is_binary(id) and id != "" do
    :hmac
    |> :crypto.mac(:sha256, subkey, tag(kind) <> id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  def hash_id(_kind, _id, _subkey), do: "none"

  defp tag(:user), do: "user:"
  defp tag(:tenant), do: "tenant:"

  @doc """
  The 32-byte derived hash key (see moduledoc). Falls back to a per-boot random
  key only if the master key is not a 32-byte binary (cannot happen after a
  successful boot).
  """
  @spec subkey() :: binary()
  def subkey do
    master =
      case Application.get_env(:letflow, :secrets_master_key) do
        k when is_binary(k) and byte_size(k) == 32 -> k
        _other -> fallback_key()
      end

    :crypto.mac(:hmac, :sha256, master, @label <> <<1>>)
  end

  defp fallback_key do
    key =
      case :persistent_term.get(@fallback_key, nil) do
        nil ->
          k = :crypto.strong_rand_bytes(32)
          :persistent_term.put(@fallback_key, k)
          k

        k ->
          k
      end

    if :persistent_term.get(@fallback_noted_key, nil) == nil do
      :persistent_term.put(@fallback_noted_key, true)
      Logger.warning("authz deny log hash key fallback in use")
    end

    key
  end

  @doc """
  The route template of the matched route with the `forward` glob removed, or
  `"unmatched"` when no route was recorded or the value is not printable ASCII.
  """
  @spec route_pattern(Plug.Conn.t()) :: String.t()
  def route_pattern(conn) do
    if Map.has_key?(conn.private, :plug_route) do
      pattern = conn |> Plug.Router.match_path() |> String.replace("/*glob", "")
      if printable?(pattern), do: pattern, else: "unmatched"
    else
      "unmatched"
    end
  rescue
    _ -> "unmatched"
  end

  @doc "Allow-listed HTTP method token; anything else is `\"OTHER\"`."
  @spec method_token(term()) :: String.t()
  def method_token(m) when is_binary(m) and m in @methods, do: m
  def method_token(_m), do: "OTHER"

  @doc "Printable policy-key atom name, or `\"unknown\"`."
  @spec policy_token(term()) :: String.t()
  def policy_token(key) when is_atom(key) do
    name = Atom.to_string(key)
    if printable?(name), do: name, else: "unknown"
  end

  def policy_token(_key), do: "unknown"

  defp printable?(s), do: Regex.match?(~r/\A[\x21-\x7E]{1,200}\z/, s)

  @doc """
  Whether the policy being enforced is platform-scope. Markers are mapped
  explicitly; any failure fails closed (`true`).
  """
  @spec platform_scope?(policy_key()) :: boolean()
  def platform_scope?(:UnmatchedPlatformPath), do: true
  def platform_scope?(:UnmatchedRoute), do: false
  def platform_scope?(:Unknown), do: false

  def platform_scope?(key) do
    key |> Authorization.required_permission() |> Authorization.permission_scope() == :platform
  rescue
    _ -> true
  end

  @doc false
  # TEST ONLY: zero the sampler and clear one-time flags and the fallback key.
  @spec reset() :: :ok
  def reset do
    case :persistent_term.get(@sampler_key, nil) do
      {last, supp} ->
        Enum.each(1..@slots, fn i ->
          :atomics.put(last, i, 0)
          :atomics.put(supp, i, 0)
        end)

      _ ->
        :ok
    end

    :persistent_term.erase(@fallback_key)
    :persistent_term.erase(@fallback_noted_key)

    for {{__MODULE__, :failure_noted, _class, _mod} = k, _v} <- :persistent_term.get() do
      :persistent_term.erase(k)
    end

    :ok
  end

  # --- sampling -----------------------------------------------------------

  # Fail-open: a broken sampler must never silence security logging.
  defp sample(policy_key, caller, tenant) do
    do_sample(policy_key, caller, tenant)
  rescue
    _ -> {:emit, 0}
  catch
    _kind, _reason -> {:emit, 0}
  end

  defp do_sample(policy_key, caller, tenant) do
    case window() do
      0 ->
        {:emit, 0}

      window ->
        {last_ref, supp_ref} = sampler()
        slot = :erlang.phash2({policy_key, caller, tenant}, @slots) + 1
        now = now()
        last = :atomics.get(last_ref, slot)

        if last == 0 or now < last or now - last >= window do
          case :atomics.compare_exchange(last_ref, slot, last, now) do
            :ok -> {:emit, :atomics.exchange(supp_ref, slot, 0)}
            _lost -> suppress(supp_ref, slot)
          end
        else
          suppress(supp_ref, slot)
        end
    end
  end

  defp suppress(supp_ref, slot) do
    :atomics.add(supp_ref, slot, 1)
    :suppress
  end

  defp window do
    case Application.get_env(:letflow, :authz_deny_log_window_s, @default_window) do
      w when is_integer(w) and w >= 0 -> w
      _invalid -> @default_window
    end
  end

  # Test-only injectable clock (`:authz_deny_log_clock`, zero-arity fun).
  defp now do
    case Application.get_env(:letflow, :authz_deny_log_clock) do
      f when is_function(f, 0) -> f.() |> must_be_integer()
      _ -> System.system_time(:second)
    end
  end

  defp must_be_integer(i) when is_integer(i), do: i

  defp sampler do
    case :persistent_term.get(@sampler_key, nil) do
      nil ->
        pair = {
          :atomics.new(@slots, signed: true),
          :atomics.new(@slots, signed: true)
        }

        :persistent_term.put(@sampler_key, pair)
        pair

      pair ->
        pair
    end
  end

  # --- failure path -------------------------------------------------------

  # `rescue` only binds exception structs, so the struct module is always present.
  defp exception_module(%{__struct__: mod}), do: mod

  # Logs only constants plus class and exception module name, once per boot per
  # {class, module}. Never a message, reason, stacktrace or id.
  defp note_failure(class, mod) do
    flag = {__MODULE__, :failure_noted, class, mod}

    if :persistent_term.get(flag, nil) == nil do
      :persistent_term.put(flag, true)

      Logger.warning(
        "authz_deny_log_failed class=#{class} exception=#{if mod, do: Atom.to_string(mod), else: "none"}"
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end
end
