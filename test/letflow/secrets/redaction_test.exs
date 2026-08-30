defmodule Letflow.Secrets.RedactionTest do
  @moduledoc """
  Tests for REQ-190 -- `Letflow.Secrets.Redaction` (`redact_map/1`,
  `render_reference/1`), and a moduledoc-honesty check. See `test/specs/REQ-190.md`
  for the full acceptance-criterion -> test-case mapping. Design authority:
  `lib/letflow/design/req190-secrets-core.md` §6.1.

  Pure functions, no I/O, no DB -- plain `ExUnit.Case, async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Secrets.Redaction

  # ---------------------------------------------------------------------------------
  # AC7 -- redaction of the exact key list
  # ---------------------------------------------------------------------------------

  describe "AC7: redact_map/1 redacts the exact key list, keeps key names, leaves unlisted keys alone" do
    test "redact_map exact keys" do
      input = %{
        "secret" => "s3cr3t-value",
        "password" => "p@ssword-value",
        "token" => "tok-value",
        "client_secret" => "cs-value",
        "my_custom_secret" => "suffix-matched-value",
        "harmless" => "plain-value"
      }

      redacted = Redaction.redact_map(input)

      assert redacted["secret"] == "[REDACTED]"
      assert redacted["password"] == "[REDACTED]"
      assert redacted["token"] == "[REDACTED]"
      assert redacted["client_secret"] == "[REDACTED]"
      assert redacted["my_custom_secret"] == "[REDACTED]"

      # Negative case: an unlisted key must NOT be redacted -- proves this isn't a
      # bug that redacts every value indiscriminately.
      assert redacted["harmless"] == "plain-value"

      # Every key name is kept, unmodified, regardless of whether its value was
      # redacted.
      assert Map.keys(redacted) |> Enum.sort() == Map.keys(input) |> Enum.sort()
    end

    test "keys are matched case-insensitively, and via atom keys too" do
      input = %{"SECRET" => "v1", :password => "v2", "Api_Token" => "v3"}

      redacted = Redaction.redact_map(input)

      assert redacted["SECRET"] == "[REDACTED]"
      assert redacted[:password] == "[REDACTED]"
      assert redacted["Api_Token"] == "[REDACTED]"
    end

    test "recurses into nested maps and lists of maps" do
      input = %{
        "data" => %{"nested_secret" => "inner", "safe" => "kept"},
        "items" => [%{"token" => "t1"}, %{"safe" => "kept2"}]
      }

      redacted = Redaction.redact_map(input)

      assert redacted["data"]["nested_secret"] == "[REDACTED]"
      assert redacted["data"]["safe"] == "kept"
      assert [%{"token" => "[REDACTED]"}, %{"safe" => "kept2"}] = redacted["items"]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- reference-redaction masking
  # ---------------------------------------------------------------------------------

  describe "AC8: render_reference/1 masks the key_id segment" do
    test "render_reference" do
      pinned = "sec://tenant/acme/webhook/sub-1#7"
      unpinned = "sec://tenant/acme/webhook/sub-1"

      assert Redaction.render_reference(pinned) == "sec://tenant/acme/webhook/sub-1#***"
      assert Redaction.render_reference(unpinned) == unpinned
    end
  end

  # ---------------------------------------------------------------------------------
  # AC10 -- moduledoc honest-limitation statement
  # ---------------------------------------------------------------------------------

  describe "AC10: moduledoc states the honest field-name-only limitation" do
    test "moduledoc honesty" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.Secrets.Redaction)

      assert moduledoc =~ ~r/field NAME/i

      assert moduledoc =~ "not caught" or moduledoc =~ "NOT caught"

      refute moduledoc =~ ~r/guarantees? (complete|full|all)/i
    end
  end
end
