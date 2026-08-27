defmodule Letflow.Engine.LuaNumberMarshalling do
  @moduledoc """
  REQ-150 §3 — the single named module/function pair every `platform.*` host function
  that crosses the Elixir/Lua boundary with a numeric value MUST route through, rather
  than each caller inventing its own conversion.

  Per REQ-150 §2.1/§2.2, the normative rule for `integer()`, `float()` (including
  whole-number floats), and `nil` is **identity in both directions** — no caller may
  inspect a float's fractional part and decide to hand Lua an integer instead, and no
  caller may do the reverse on the write path. Codifying identity explicitly here (rather
  than omitting numeric handling entirely) is what keeps a future maintainer from
  "helpfully" adding a coercion at some call site.

  `to_lua/1`/`from_lua/1` both accept `term()` and pass through every non-numeric,
  non-`nil` value (`String.t()`, `boolean()`, `map()`, `list()`) unchanged — REQ-150's own
  rule has nothing to say about those shapes, and this module is not the place to add
  anything that would.

  Created by REQ-159 (the first of the two sibling requirements, REQ-159/REQ-160, to need
  it — see `lib/letflow/design/req159-lua-host-api-read.md` §3) so REQ-160 only ever adds
  call sites, never a second definition. No dependency on any other module under
  `lib/letflow/engine/` (REQ-150 §6's own scope note).
  """

  @doc """
  Read-path conversion (REQ-150 §2.2) — an Elixir value already resolved (e.g. from an
  instance's `variables` map or projection) on its way to becoming Lua-visible. Identity
  for `integer()`/`float()`/`nil`; pass-through for every other `term()`.
  """
  @spec to_lua(value :: term()) :: term()
  def to_lua(value), do: value

  @doc """
  Write-path conversion (REQ-150 §2.1) — a Lua-supplied value on its way to becoming a
  stored Elixir/JSONB value. Identity for `integer()`/`float()`/`nil`; pass-through for
  every other `term()`. Not exercised by REQ-159's own functions (none of them write a
  value back) but present from the start per REQ-150 §3's instruction.
  """
  @spec from_lua(value :: term()) :: term()
  def from_lua(value), do: value
end
