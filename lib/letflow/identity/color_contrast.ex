defmodule Letflow.Identity.ColorContrast do
  @moduledoc """
  WCAG 2.1 Success Criterion 1.4.3 (AA) relative-luminance / contrast-ratio
  math (REQ-382, `lib/letflow/design/req382-tenant-branding-write-path.md`
  §2.5). Pure — no `Ecto`/`Plug`/I/O dependency — so this math is
  unit-testable in isolation from `Letflow.Identity.Tenant`'s changeset
  plumbing, which is the only caller (`validate_brand_colors/2`).

  Threshold: **4.5:1**, the "normal text" AA minimum (not the 3:1 "large
  text" allowance — `--color-brand-600` is used as ordinary link/interactive
  text size in `web/`, not exclusively large-text-sized UI, so the stricter
  threshold applies unconditionally here).
  """

  @type hex_color :: String.t()

  @aa_normal_text_min_ratio 4.5

  @doc """
  Standard sRGB relative luminance (WCAG 2.1 §1.4.3 formula, verbatim, not
  an approximation): each of R/G/B is normalized to `[0, 1]`, piecewise
  sRGB-to-linear transformed, then combined via the ITU-R BT.709 luminance
  coefficients.
  """
  @spec relative_luminance(hex_color()) :: float()
  def relative_luminance("#" <> <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    [r, g, b]
    |> Enum.map(&channel_to_linear/1)
    |> then(fn [r_lin, g_lin, b_lin] -> 0.2126 * r_lin + 0.7152 * g_lin + 0.0722 * b_lin end)
  end

  defp channel_to_linear(hex_byte) do
    c = String.to_integer(hex_byte, 16) / 255.0

    if c <= 0.03928 do
      c / 12.92
    else
      :math.pow((c + 0.055) / 1.055, 2.4)
    end
  end

  @doc """
  WCAG 2.1 contrast ratio between two colors: `(L_lighter + 0.05) /
  (L_darker + 0.05)`, where the two colors' `relative_luminance/1` values are
  ordered so the larger is always the numerator — symmetric in its two
  arguments (argument order never changes the result), matching WCAG 2.1's
  own ratio definition.
  """
  @spec contrast_ratio(hex_color(), hex_color()) :: float()
  def contrast_ratio(color_a, color_b) do
    l_a = relative_luminance(color_a)
    l_b = relative_luminance(color_b)
    {l_lighter, l_darker} = if l_a >= l_b, do: {l_a, l_b}, else: {l_b, l_a}
    (l_lighter + 0.05) / (l_darker + 0.05)
  end

  @doc "True when `foreground`/`background`'s contrast ratio meets the WCAG AA normal-text minimum (4.5:1)."
  @spec meets_wcag_aa_normal_text?(foreground :: hex_color(), background :: hex_color()) ::
          boolean()
  def meets_wcag_aa_normal_text?(foreground, background) do
    contrast_ratio(foreground, background) >= @aa_normal_text_min_ratio
  end

  @doc "The AA normal-text minimum ratio (4.5), exposed for callers that build their own error messages."
  @spec aa_normal_text_min_ratio() :: float()
  def aa_normal_text_min_ratio, do: @aa_normal_text_min_ratio
end
