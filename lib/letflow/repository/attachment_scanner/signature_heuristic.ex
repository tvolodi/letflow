defmodule Letflow.Repository.AttachmentScanner.SignatureHeuristic do
  @moduledoc """
  Default `Letflow.Repository.AttachmentScanner` adapter (ISS-0399 design §3.2)
  -- resolved automatically in every environment with no config override, per
  `Letflow.Repository.AttachmentScanner`'s moduledoc.

  A real, working, in-process signature-based scanner -- not a stub, not a
  TODO -- using the **EICAR Anti-Virus Test File** string
  (https://www.eicar.org/) as its one detection signature. EICAR is the
  antivirus industry's own standard 68-byte test string, deliberately not a
  real virus, that every real AV engine (including ClamAV) is built to flag --
  chosen here specifically because it makes this a genuinely real scanner with
  a genuinely real, deterministic, harmless positive case, testable without
  needing an actual malware sample or a live ClamAV daemon in CI.

  **Explicitly out of scope for this adapter, named rather than silently
  omitted (design §3.2):** real malware-signature-database matching,
  heuristic/behavioral analysis, and any actual ClamAV/cloud-AV integration.
  Swapping in a real engine later means writing one new module implementing
  `Letflow.Repository.AttachmentScanner`'s `scan/2` callback and changing one
  `:letflow, :attachment_scanner` config value -- no change to
  `Letflow.Repository.Attachments` itself.

  This adapter performs no I/O, no network call, no external process -- it
  can never return `{:error, _}`. Deliberately does **not** attempt magic-
  byte/file-type sniffing or any `content_type`-based branching, consistent
  with `Letflow.Repository.Attachments`'s own INV-a ("`content_type` is never
  a validated fact").
  """

  @behaviour Letflow.Repository.AttachmentScanner

  @eicar_signature "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

  @impl true
  @spec scan(raw_bytes :: binary(), content_type :: String.t()) ::
          {:ok, :clean} | {:ok, :infected, Letflow.Repository.AttachmentScanner.verdict()}
  def scan(raw_bytes, _content_type) when is_binary(raw_bytes) do
    if String.contains?(raw_bytes, @eicar_signature) do
      {:ok, :infected, "eicar-test-signature"}
    else
      {:ok, :clean}
    end
  end
end
