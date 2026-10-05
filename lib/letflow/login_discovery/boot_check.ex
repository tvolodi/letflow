defmodule Letflow.LoginDiscovery.BootCheck do
  @moduledoc """
  Pure boot gate for enabling email-first login outside dev/test (REQ-444,
  decision 0043 D-D, 0042 OQ-3). `config/runtime.exs` calls `check/4` with the
  already-parsed flag, the legal-confirmation marker, and the configured
  notifier adapter module; this module reads no config or environment itself.

  What it gates, outside `:dev`/`:test` and only when the feature is enabled:

    1. a non-blank legal-confirmation marker
       (`LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION`) must be present, and
    2. the notifier adapter must be one that really delivers email
       (`LETFLOW_MAIL_ADAPTER`).

  The marker is ADVISORY. It cannot prove that a legal confirmation happened;
  it only makes enabling the feature without one a deliberate, auditable act.

  The delivering-adapter list is explicit and fail-closed: `nil`, the Noop
  default, the test double, and any unknown module are all rejected. The
  dev/test exemption keys on the env ATOM only.

  The pepper / key-id precondition is NOT re-implemented here; REQ-435's own
  boot checks enforce it.
  """

  # Bare atom on purpose: the Smtp adapter module is created by REQ-441.
  @delivering [Letflow.LoginDiscovery.Notifier.Smtp]
  @min_marker_length 8

  @doc "Adapter modules that really deliver email (explicit, fail-closed)."
  @spec delivering_adapters() :: [module()]
  def delivering_adapters, do: @delivering

  @doc "Minimum trimmed byte size of the legal-confirmation marker."
  @spec min_marker_length() :: pos_integer()
  def min_marker_length, do: @min_marker_length

  @doc """
  Boot decision. The marker is checked first, so a missing marker is reported
  before an unsuitable adapter.
  """
  @spec check(atom(), boolean(), String.t() | nil, module() | nil) ::
          :ok | {:error, :missing_confirmation | :adapter_not_delivering}
  def check(env, _enabled?, _marker, _adapter) when env in [:dev, :test], do: :ok
  def check(_env, false, _marker, _adapter), do: :ok

  def check(_env, true, marker, adapter) do
    cond do
      not valid_marker?(marker) -> {:error, :missing_confirmation}
      adapter in @delivering -> :ok
      true -> {:error, :adapter_not_delivering}
    end
  end

  @doc """
  Fixed boot-failure text. Names the variables, never interpolates a value
  (no marker, no adapter).
  """
  @spec message(atom()) :: String.t()
  def message(:missing_confirmation) do
    "email-first login is enabled outside dev/test but " <>
      "LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION is missing or too short; " <>
      "set it to a deliberate confirmation marker (at least #{@min_marker_length} characters) " <>
      "or leave the feature disabled"
  end

  def message(:adapter_not_delivering) do
    "email-first login is enabled outside dev/test but LETFLOW_MAIL_ADAPTER " <>
      "does not select an email-delivering adapter; configure a real mail adapter " <>
      "or leave the feature disabled"
  end

  def message(_reason) do
    "email-first login enablement gate failed; check " <>
      "LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION and LETFLOW_MAIL_ADAPTER"
  end

  defp valid_marker?(marker) when is_binary(marker),
    do: byte_size(String.trim(marker)) >= @min_marker_length

  defp valid_marker?(_), do: false
end
