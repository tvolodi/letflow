defmodule Letflow.Repository.CanonicaliserTest do
  @moduledoc """
  Unit tests for `Letflow.Repository.Canonicaliser` (REQ-202, REPO-04). See
  `test/specs/REQ-202.md` for the full acceptance-criteria-to-test-case
  mapping.

  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency anywhere in this
  file -- `async: true` is correct here, matching
  `test/letflow/definitions/promotion_digest_test.exs`'s own precedent for a
  zero-I/O module.

  Covers AC2 (key-order/whitespace insensitivity), AC3 (number
  normalisation), AC4 (byte-identity for non-JSON content, plus OQ-3's
  narrow content-type-matching rule), and the moduledoc-cross-reference half
  of AC5 (the separate-module half and the "PromotionDigest not modified in
  behavior" half are covered in `test/letflow/repository_test.exs`, which
  computes a fixed fixture through the real `PromotionDigest` -- AC6).
  """

  use ExUnit.Case, async: true

  alias Letflow.Repository.Canonicaliser

  # ---------------------------------------------------------------------------------
  # AC2 -- key-order and whitespace insensitivity of the hash.
  #
  # A broken implementation that canonicalized by simply re-encoding raw
  # `Jason.decode!/1` output WITHOUT sorting keys would still collapse
  # whitespace, but would NOT produce the same bytes for the two key orders
  # below -- this test would catch that specific mutant.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- key order and insignificant whitespace do not affect the hash" do
    test "two JSON texts differing only in key order and whitespace produce byte-identical canonical output and the same hash" do
      doc_compact_reverse_order = ~s({"b":2,"a":1})
      doc_spaced_forward_order = ~s({ "a" : 1 , "b" : 2 })

      assert {:ok, canonical_1} =
               Canonicaliser.canonicalize_content("application/json", doc_compact_reverse_order)

      assert {:ok, canonical_2} =
               Canonicaliser.canonicalize_content("application/json", doc_spaced_forward_order)

      assert canonical_1 == canonical_2
      assert Canonicaliser.content_hash(canonical_1) == Canonicaliser.content_hash(canonical_2)

      # Sanity: the canonical form actually carries no insignificant
      # whitespace (rule 2) -- guards against a mutant that sorts keys but
      # forgets Jason's compact default.
      refute canonical_1 =~ ~r/\s/
    end

    test "nested objects are also key-sorted recursively, not just the top level" do
      doc_a = ~s({"outer":{"z":1,"a":2},"first":true})
      doc_b = ~s({"first":true,"outer":{"a":2,"z":1}})

      assert {:ok, canonical_1} = Canonicaliser.canonicalize_content("application/json", doc_a)
      assert {:ok, canonical_2} = Canonicaliser.canonicalize_content("application/json", doc_b)

      assert canonical_1 == canonical_2
    end

    test "arrays are NOT reordered -- differing array element order changes the hash (rule 4, sanity check for the key-sort test above)" do
      doc_forward = ~s({"list":[1,2,3]})
      doc_reversed = ~s({"list":[3,2,1]})

      assert {:ok, canonical_1} =
               Canonicaliser.canonicalize_content("application/json", doc_forward)

      assert {:ok, canonical_2} =
               Canonicaliser.canonicalize_content("application/json", doc_reversed)

      refute canonical_1 == canonical_2

      refute Canonicaliser.content_hash(canonical_1) == Canonicaliser.content_hash(canonical_2)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- number normalisation: an integer-valued float and the corresponding
  # integer produce byte-identical canonical bytes, asserted on the bytes
  # themselves (not only the hash), and the canonical form of an integer
  # carries no decimal point.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- integer-valued floats normalise to plain integers" do
    test "2.0 and 2 produce byte-identical canonical bytes, and the canonical form has no decimal point" do
      doc_float = ~s({"n":2.0})
      doc_int = ~s({"n":2})

      assert {:ok, canonical_float} =
               Canonicaliser.canonicalize_content("application/json", doc_float)

      assert {:ok, canonical_int} =
               Canonicaliser.canonicalize_content("application/json", doc_int)

      assert canonical_float == canonical_int
      assert canonical_float == ~s({"n":2})
      refute canonical_float =~ "."

      assert Canonicaliser.content_hash(canonical_float) ==
               Canonicaliser.content_hash(canonical_int)
    end

    test "an integer-valued float in exponent form (3.0e2) also normalises to the plain integer 300, no exponent, no decimal point" do
      doc_exponent = ~s({"n":3.0e2})
      doc_plain_int = ~s({"n":300})

      assert {:ok, canonical_exponent} =
               Canonicaliser.canonicalize_content("application/json", doc_exponent)

      assert {:ok, canonical_plain} =
               Canonicaliser.canonicalize_content("application/json", doc_plain_int)

      assert canonical_exponent == canonical_plain
      assert canonical_exponent == ~s({"n":300})
      refute canonical_exponent =~ "."
      refute canonical_exponent =~ ~r/[eE]/
    end

    test "a genuinely fractional float (2.5) is NOT collapsed to an integer -- it round-trips distinctly from both 2 and 3" do
      assert {:ok, canonical_fractional} =
               Canonicaliser.canonicalize_content("application/json", ~s({"n":2.5}))

      assert {:ok, canonical_two} =
               Canonicaliser.canonicalize_content("application/json", ~s({"n":2}))

      assert {:ok, canonical_three} =
               Canonicaliser.canonicalize_content("application/json", ~s({"n":3}))

      refute canonical_fractional == canonical_two
      refute canonical_fractional == canonical_three
      assert canonical_fractional =~ "2.5"
    end

    test "malformed JSON under content_type application/json is {:error, :invalid_json}" do
      assert Canonicaliser.canonicalize_content("application/json", "{not valid json") ==
               {:error, :invalid_json}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- binary (non-JSON) content is hashed by byte identity, asserted by
  # showing its hash equals a plain SHA-256 of the exact submitted bytes.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- byte-identity for non-JSON content" do
    test "content_type application/wasm is passed through byte-for-byte and hashed with plain SHA-256" do
      raw_bytes = <<0, 97, 115, 109, 1, 0, 0, 0, 255, 254, 253>>

      assert {:ok, canonical} = Canonicaliser.canonicalize_content("application/wasm", raw_bytes)
      assert canonical == raw_bytes

      assert Canonicaliser.content_hash(canonical) == :crypto.hash(:sha256, raw_bytes)
    end

    test "byte identity holds even when the bytes happen to be well-formed, differently-ordered JSON -- non-JSON content_type means no canonicalisation is applied at all" do
      # If canonicalize_content/2 mistakenly treated a non-"application/json"
      # content_type as JSON-ish, this reordered/whitespace-different text
      # would canonicalize to the SAME bytes as the other ordering (per the
      # AC2 test above) and this assertion would fail -- pinning OQ-3's
      # narrow "exact match only" reading.
      raw_a = ~s({"b":2,"a":1})
      raw_b = ~s({ "a" : 1 , "b" : 2 })

      assert {:ok, canonical_a} =
               Canonicaliser.canonicalize_content("application/schema+json", raw_a)

      assert {:ok, canonical_b} =
               Canonicaliser.canonicalize_content("application/schema+json", raw_b)

      assert canonical_a == raw_a
      assert canonical_b == raw_b
      refute canonical_a == canonical_b

      assert Canonicaliser.content_hash(canonical_a) == :crypto.hash(:sha256, raw_a)
    end

    test "a parameterized JSON content_type (application/json; charset=utf-8) is NOT treated as JSON either -- exact-match only (OQ-3)" do
      raw = ~s({"b":2,"a":1})

      assert {:ok, canonical} =
               Canonicaliser.canonicalize_content("application/json; charset=utf-8", raw)

      assert canonical == raw
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- separate-module half: the moduledoc states the required
  # cross-reference to `Letflow.Definitions.PromotionDigest`, in the terms
  # the design mandates (design §3.2). The "PromotionDigest unmodified in
  # behavior" half and the reciprocal moduledoc are covered in
  # test/letflow/repository_test.exs (AC5/AC6).
  # ---------------------------------------------------------------------------------

  describe "AC5 -- Canonicaliser's moduledoc cross-references PromotionDigest" do
    test "the moduledoc names Letflow.Definitions.PromotionDigest, states it does NOT normalize numbers, and states the two must never be merged" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.Repository.Canonicaliser)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      assert normalized =~ "Letflow.Definitions.PromotionDigest",
             "moduledoc does not name PromotionDigest: #{normalized}"

      assert normalized =~ "does NOT normalize numbers",
             "moduledoc does not state PromotionDigest's non-normalizing behavior: #{normalized}"

      assert normalized =~ "must never be merged",
             "moduledoc does not state the two must never be merged: #{normalized}"

      assert normalized =~ "REQ-036",
             "moduledoc does not cite REQ-036, PromotionDigest's own requirement: #{normalized}"
    end
  end
end
