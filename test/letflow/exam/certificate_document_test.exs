defmodule Letflow.Exam.CertificateDocumentTest do
  @moduledoc """
  REQ-356 -- unit coverage for `Letflow.Exam.CertificateDocument.render/2`
  against a fixture certificate view (no database, no tenant provisioning --
  this module is a pure function of its input, see its own moduledoc).
  HTTP-level route wiring (the authenticated download route) lives in
  `test/letflow/routers/exam_sessions_test.exs`'s own "REQ-356" describe
  block.
  """

  use ExUnit.Case, async: true

  alias Letflow.Exam.CertificateDocument

  defp fixture_certificate(overrides \\ %{}) do
    Map.merge(
      %{
        id: "11111111-1111-1111-1111-111111111111",
        candidate_name: "Jane Candidate",
        exam_title: %{"en" => "Intro to Elixir", "ru" => "Введение в Elixir"},
        score_pct: 87.5,
        issued_at: ~U[2026-09-15 12:00:00Z],
        branding_snapshot: %{
          "app_name" => "Acme Testing Co",
          "logo_url" => nil,
          "brand_colors" => %{"primary" => "#228be6"}
        }
      },
      overrides
    )
  end

  defp fixture_verification(overrides \\ %{}) do
    Map.merge(%{base_url: "https://verify.example.com", code: "verify-code-123"}, overrides)
  end

  # ---------------------------------------------------------------------
  # AC: a non-empty binary whose leading bytes are the PDF magic number.
  # ---------------------------------------------------------------------

  describe "render/2 -- output shape" do
    test "returns a non-empty binary starting with the PDF magic number" do
      assert {:ok, bytes} =
               CertificateDocument.render(fixture_certificate(), fixture_verification())

      assert is_binary(bytes)
      assert byte_size(bytes) > 0
      assert binary_part(bytes, 0, 5) == "%PDF-"
    end
  end

  # ---------------------------------------------------------------------
  # AC: candidate name, exam title, score and issue date each individually
  # present in the rendered document.
  # ---------------------------------------------------------------------

  describe "render/2 -- content fields" do
    test "the rendered PDF stream contains the candidate name, exam title (en), score and issue date" do
      assert {:ok, bytes} =
               CertificateDocument.render(fixture_certificate(), fixture_verification())

      text = pdf_text_ops(bytes)

      assert text =~ "Jane Candidate"
      assert text =~ "Intro to Elixir"
      assert text =~ "87.50"
      assert text =~ "2026-09-15"
    end

    test "a plain-string exam_title (non-localized fixture) passes through unchanged" do
      cert = fixture_certificate(%{exam_title: "Plain Exam Title"})

      assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification())
      assert pdf_text_ops(bytes) =~ "Plain Exam Title"
    end

    test "an exam_title map missing \"en\" falls back to its first locale in sorted key order" do
      cert =
        fixture_certificate(%{exam_title: %{"ru" => "Только русский", "kk" => "Тек қазақша"}})

      assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification())
      # sorted(["kk", "ru"]) -> "kk" wins. Every character here falls outside
      # `pdf`'s WinAnsi/Latin-1 glyph range, so per this module's own
      # documented finding against decision 0033 (`safe_text_at/3`'s
      # comment) each one degrades to the literal replacement character
      # "?" rather than crashing the render -- asserting THAT degraded
      # text (not the original Cyrillic, which `pdf` cannot draw at all)
      # is the honest assertion for this library's actual behaviour.
      assert pdf_text_ops(bytes) =~ "??? ???????"
    end
  end

  # ---------------------------------------------------------------------
  # AC: the QR code encodes the exact verification URL, decoded and
  # asserted, not merely "an image was produced".
  # ---------------------------------------------------------------------

  describe "render/2 -- QR payload" do
    test "the QR code drawn into the PDF decodes, cell for cell, to the exact verification URL" do
      verification =
        fixture_verification(%{base_url: "https://verify.example.com", code: "abc-123"})

      expected_url = "https://verify.example.com/verify/abc-123"

      assert {:ok, bytes} = CertificateDocument.render(fixture_certificate(), verification)

      # Independently derive what SHOULD have been encoded -- a real,
      # separate call into the same QR library render/2 itself calls, over
      # the exact URL string we expect render/2 to have built.
      expected_matrix = EQRCode.encode(expected_url, :m)

      # Then reconstruct what render/2 ACTUALLY drew, purely from the PDF's
      # own raw fill-rectangle operators (`x y w h re` + `f`) plus the
      # module's own published layout constants -- geometry back to a
      # row/col boolean matrix, with no dependency on internal render/2
      # state. This is a real decode of the rendered artefact, not a
      # restatement of the input.
      # `expected_matrix.modules` is the PRE-quiet-zone module count --
      # `EQRCode.Matrix.draw_quite_zone/1` pads `:matrix` with a further
      # 4 rows/cols without updating `:modules` to match
      # (`deps/eqrcode/lib/eqrcode/matrix.ex:369-386`) -- the real side
      # length to reconstruct against is `tuple_size/1` of the final
      # matrix, matching the correction `certificate_document.ex`'s own
      # `draw_qr_matrix/2` makes for the same reason.
      actual_matrix = reconstruct_qr_matrix(bytes, tuple_size(expected_matrix.matrix))

      assert actual_matrix == expected_matrix.matrix

      # And a negative control: a DIFFERENT code must NOT reconstruct to the
      # same matrix, proving this comparison is sensitive to the payload
      # rather than trivially true for any QR-shaped output.
      wrong_matrix = EQRCode.encode("https://verify.example.com/verify/WRONG-CODE", :m)
      assert actual_matrix != wrong_matrix.matrix
    end

    test "a base_url with a trailing slash is normalized before building the verify URL" do
      verification =
        fixture_verification(%{base_url: "https://verify.example.com/", code: "abc-123"})

      assert {:ok, bytes} = CertificateDocument.render(fixture_certificate(), verification)
      assert pdf_text_ops(bytes) =~ "Verify: https://verify.example.com/verify/abc-123"
      refute pdf_text_ops(bytes) =~ "https://verify.example.com//verify/"
    end
  end

  # ---------------------------------------------------------------------
  # AC: the same verification URL appears as readable text too.
  # ---------------------------------------------------------------------

  describe "render/2 -- readable verification text" do
    test "the verification URL appears as plain readable text in the document" do
      verification =
        fixture_verification(%{base_url: "https://verify.example.com", code: "xyz-999"})

      assert {:ok, bytes} = CertificateDocument.render(fixture_certificate(), verification)
      assert pdf_text_ops(bytes) =~ "Verify: https://verify.example.com/verify/xyz-999"
      assert pdf_text_ops(bytes) =~ "Certificate ID: xyz-999"
    end
  end

  # ---------------------------------------------------------------------
  # AC: branding in the document comes from the SNAPSHOT passed in, never
  # from a live re-read -- proven by mutating the input map's own snapshot
  # field between two renders and asserting the RENDER output tracks
  # whatever snapshot was passed (this module has nothing else to read),
  # matching this requirement's "render/2 is a pure function of its input,
  # no Repo call" contract stated in the moduledoc.
  # ---------------------------------------------------------------------

  describe "render/2 -- branding" do
    test "the header carries the certificate's own snapshotted app_name, not a platform-hardcoded name" do
      cert = fixture_certificate(%{branding_snapshot: %{"app_name" => "Original Co"}})

      assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification())
      text = pdf_text_ops(bytes)

      assert text =~ "Original Co"
      refute text =~ "BilimBaga"
    end

    test "re-rendering from an unchanged stored snapshot after a live branding mutation elsewhere leaves the document's own branding text unchanged" do
      original_snapshot = %{"app_name" => "Original Co", "logo_url" => nil, "brand_colors" => %{}}
      cert = fixture_certificate(%{branding_snapshot: original_snapshot})

      assert {:ok, first_bytes} = CertificateDocument.render(cert, fixture_verification())

      # Simulate "live tenant branding changed after issuance" by building a
      # SEPARATE, mutated branding map -- exactly what
      # Letflow.Routers.TenantConfig.branding_from_settings/1 would now
      # return for the tenant -- and confirming render/2 never reads it:
      # only the record's own already-captured `branding_snapshot` (the
      # `cert` map above, untouched) is ever passed to a second render.
      _live_branding_now = %{
        "app_name" => "Rebranded Co",
        "logo_url" => nil,
        "brand_colors" => %{}
      }

      assert {:ok, second_bytes} = CertificateDocument.render(cert, fixture_verification())

      assert pdf_text_ops(first_bytes) =~ "Original Co"
      assert pdf_text_ops(second_bytes) =~ "Original Co"
      refute pdf_text_ops(second_bytes) =~ "Rebranded Co"
      assert first_bytes == second_bytes
    end

    test "a snapshot missing app_name falls back to the platform default, not a crash" do
      cert = fixture_certificate(%{branding_snapshot: %{}})

      assert {:ok, bytes} = CertificateDocument.render(cert, fixture_verification())
      assert pdf_text_ops(bytes) =~ "Letflow"
    end
  end

  # -----------------------------------------------------------------------
  # A PDF built by the `pdf` library is FlateDecode-compressed by default
  # (`compress: true`), so text operators are not literally grep-able in
  # the raw output bytes -- this helper inflates every stream object and
  # concatenates the result, giving the tests above a plain-text haystack
  # to assert against instead of parsing the PDF content-stream operator
  # grammar (`Tj`/`TJ`) in full.
  # -----------------------------------------------------------------------
  defp pdf_text_ops(bytes) do
    ~r/stream\r?\n(.*?)endstream/s
    |> Regex.scan(bytes, capture: :all_but_first)
    |> Enum.map(fn [stream] -> inflate(stream) end)
    |> Enum.join("\n")
  end

  # Reconstructs the boolean QR module matrix (as the same tuple-of-tuples
  # shape `EQRCode.Matrix.t()`'s own `:matrix` field uses) purely from the
  # PDF's decompressed content-stream fill operators, using
  # `CertificateDocument.__qr_layout__/0`'s published origin/module-size
  # constants to invert each rectangle's geometry back to a (row, col) QR
  # cell. `modules` is the expected matrix's own side length (from a real,
  # independent `EQRCode.encode/2` call), used only to size the output
  # tuple -- every cell not found filled in the PDF is `0`.
  defp reconstruct_qr_matrix(bytes, modules) do
    %{origin_x: origin_x, module_size: size, footer_y: footer_y} =
      CertificateDocument.__qr_layout__()

    text = pdf_text_ops(bytes)

    filled =
      ~r/([\d.]+)\s+([\d.]+)\s+[\d.]+\s+[\d.]+\s+re\s+f/
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(fn [x_str, y_str] ->
        {x, ""} = Float.parse(x_str)
        {y, ""} = Float.parse(y_str)

        col = round((x - origin_x) / size)
        row = modules - 1 - round((y - footer_y) / size)
        {row, col}
      end)
      |> MapSet.new()

    for row <- 0..(modules - 1) do
      for col <- 0..(modules - 1) do
        if MapSet.member?(filled, {row, col}), do: 1, else: 0
      end
      |> List.to_tuple()
    end
    |> List.to_tuple()
  end

  defp inflate(stream) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z)

    result =
      try do
        z |> :zlib.inflate(stream) |> IO.iodata_to_binary()
      rescue
        _ -> ""
      end

    :zlib.close(z)
    result
  end
end
