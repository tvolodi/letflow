defmodule Letflow.Definitions.PromotionDigestTest do
  @moduledoc """
  Unit tests for `Letflow.Definitions.PromotionDigest.compute_plan_digest/1` and
  `.verify_digest/2` (REQ-036, PRM-03). See `test/specs/REQ-036.md` for the full
  test-case rationale.

  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency anywhere in this file --
  `async: true` is correct here, matching `test/letflow/definitions/graph_test.exs`'s
  own precedent for a zero-I/O module.

  `compute_plan_digest/1` accepts any `%{entries: [...]}`-shaped map (design §7,
  structural typing -- no compile-time dependency on `PromotionPlan.t()`), so every
  fixture below is a bare map literal, not a real `PromotionPlan.compute_promotion_plan/5`
  result.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.PromotionDigest

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 5: "compute_plan_digest/1 called twice on plans with
  # identical content but differently-ordered map keys produces the identical
  # digest, demonstrated by an explicit test constructing the same entries in two
  # different key orders"
  #
  # Two INDEPENDENT examples below (not just one), per this run's explicit
  # instruction -- each pair is logically identical content, with every map's keys
  # (including nested ones) written in a different literal order in the source.
  # ---------------------------------------------------------------------------------

  describe "compute_plan_digest/1 -- acceptance criterion 5 (key-order independence), example 1" do
    test "a single-entry plan with keys reordered (including the nested `after` map) produces the identical digest" do
      plan_a = %{
        entries: [
          %{
            type: :graph_node,
            id: "n1",
            change_kind: :added,
            before: nil,
            after: %{"id" => "n1", "node_type" => "START"}
          }
        ]
      }

      plan_b = %{
        entries: [
          %{
            after: %{"node_type" => "START", "id" => "n1"},
            before: nil,
            change_kind: :added,
            id: "n1",
            type: :graph_node
          }
        ]
      }

      assert PromotionDigest.compute_plan_digest(plan_a) == PromotionDigest.compute_plan_digest(plan_b)
    end
  end

  describe "compute_plan_digest/1 -- acceptance criterion 5 (key-order independence), example 2" do
    test "a multi-entry plan with deeply nested maps, keys reordered at every level, produces the identical digest" do
      plan_c = %{
        entries: [
          %{
            type: :service_binding,
            id: "n2",
            change_kind: :modified,
            before: "svc-old",
            after: "svc-new"
          },
          %{
            type: :module_ref,
            id: "n3",
            change_kind: :removed,
            before: %{"ref" => "m1", "version" => "1", "meta" => %{"owner" => "team-a"}},
            after: nil
          }
        ]
      }

      plan_d = %{
        entries: [
          %{
            before: "svc-old",
            after: "svc-new",
            id: "n2",
            change_kind: :modified,
            type: :service_binding
          },
          %{
            after: nil,
            before: %{
              "meta" => %{"owner" => "team-a"},
              "version" => "1",
              "ref" => "m1"
            },
            change_kind: :removed,
            id: "n3",
            type: :module_ref
          }
        ]
      }

      assert PromotionDigest.compute_plan_digest(plan_c) == PromotionDigest.compute_plan_digest(plan_d)
    end
  end

  describe "compute_plan_digest/1 -- sanity checks around the key-order-independence guarantee" do
    test "differing CONTENT (not just key order) produces a different digest" do
      plan_1 = %{
        entries: [
          %{type: :graph_node, id: "n1", change_kind: :added, before: nil, after: %{"a" => 1}}
        ]
      }

      plan_2 = %{
        entries: [
          %{type: :graph_node, id: "n1", change_kind: :added, before: nil, after: %{"a" => 2}}
        ]
      }

      refute PromotionDigest.compute_plan_digest(plan_1) == PromotionDigest.compute_plan_digest(plan_2)
    end

    test "the returned digest is a 64-char lowercase hex string" do
      digest = PromotionDigest.compute_plan_digest(%{entries: []})

      assert String.length(digest) == 64
      assert digest =~ ~r/^[0-9a-f]{64}$/
    end

    test "entries LIST order is significant -- reordering the entries list itself changes the digest (design §2.5/§5.1: object keys are sorted, arrays are not)" do
      entry_1 = %{type: :graph_node, id: "n1", change_kind: :added, before: nil, after: nil}
      entry_2 = %{type: :graph_node, id: "n2", change_kind: :removed, before: nil, after: nil}

      digest_forward = PromotionDigest.compute_plan_digest(%{entries: [entry_1, entry_2]})
      digest_reversed = PromotionDigest.compute_plan_digest(%{entries: [entry_2, entry_1]})

      refute digest_forward == digest_reversed
    end

    test "nil-valued keys are never dropped during canonicalization -- a nil-valued key changes the digest versus that key being entirely absent" do
      with_nil_key = %{entries: [%{a: nil, b: 1}]}
      without_key = %{entries: [%{b: 1}]}

      refute PromotionDigest.compute_plan_digest(with_nil_key) ==
               PromotionDigest.compute_plan_digest(without_key)
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 6: "verify_digest/2 uses a constant-time comparison, not
  # Kernel.==/2 or :erlang.=:=/2 directly on the two strings, and this choice is
  # stated in the moduledoc"
  # ---------------------------------------------------------------------------------

  describe "verify_digest/2 -- acceptance criterion 6, behavior" do
    test "against the plan itself -- true for the digest that plan actually produces" do
      plan = %{
        entries: [
          %{type: :graph_node, id: "n1", change_kind: :added, before: nil, after: %{"x" => 1}}
        ]
      }

      digest = PromotionDigest.compute_plan_digest(plan)

      assert PromotionDigest.verify_digest(digest, plan) == true
    end

    test "against the plan itself -- false for a same-length but wrong digest" do
      plan = %{
        entries: [
          %{type: :graph_node, id: "n1", change_kind: :added, before: nil, after: %{"x" => 1}}
        ]
      }

      real_digest = PromotionDigest.compute_plan_digest(plan)
      wrong_digest = String.duplicate("0", 64)

      refute real_digest == wrong_digest
      assert PromotionDigest.verify_digest(wrong_digest, plan) == false
    end

    test "digest-vs-digest form (plan_or_digest is a binary already in digest shape) -- direct comparison, no recompute" do
      digest = PromotionDigest.compute_plan_digest(%{entries: []})

      assert PromotionDigest.verify_digest(digest, digest) == true
      assert PromotionDigest.verify_digest(digest, String.duplicate("f", 64)) == false
    end

    test "comparing against a differently-SIZED binary raises (real :crypto.hash_equals/2 semantics -- confirmed directly, not assumed) rather than silently returning false" do
      digest = PromotionDigest.compute_plan_digest(%{entries: []})

      # Confirmed via `elixir -e 'IO.inspect(:crypto.hash_equals("abc", "ab"))'` while
      # writing this test: OTP's :crypto.hash_equals/2 raises ArgumentError when the
      # two binaries differ in length, it does not return false. Pinning this exact,
      # non-obvious behavior here so a future divergence (e.g. someone swapping in a
      # manual byte-compare "for safety") is caught.
      assert_raise ArgumentError, fn ->
        PromotionDigest.verify_digest(digest, "too-short")
      end
    end
  end

  describe "verify_digest/2 -- acceptance criterion 6, moduledoc states the constant-time-comparison choice" do
    test "PromotionDigest's moduledoc explicitly states verify_digest/2 never uses Kernel.==/2 or :erlang.=:=/2, and names :crypto.hash_equals/2" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(PromotionDigest)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      assert normalized =~ ":crypto.hash_equals/2"

      assert normalized =~ "never `Kernel.==/2` or `:erlang.=:=/2` directly on the two digest strings",
             "moduledoc does not state the constant-time-comparison choice in the exact terms AC6 asks for: #{normalized}"
    end
  end
end
