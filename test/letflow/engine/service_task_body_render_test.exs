defmodule Letflow.Engine.ServiceTaskBodyRenderTest do
  @moduledoc """
  ISS-0926 -- unit tests (design section 6.1, T-R1..T-R21) for
  `Letflow.Engine.ServiceTask.render_body_template/2`, `body_has_placeholders?/1`,
  `body_render_reason_class/1` and `build_body_render_error_attrs/1`.

  Pure, no database, `async: true`. Every test goes through the PUBLIC functions only.
  See `test/specs/ISS-0926.md` for the per-test rationale and the pre-fix / mutant record.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Letflow.Engine.ServiceTask

  # `{"r":"` (6) + `"}` (2) = 8 template bytes around the one placeholder.
  @template_overhead 8
  @size_cap 65_536

  defp render_r(value) do
    ServiceTask.render_body_template(~s({"r":"{{variables.v}}"}), %{"v" => value})
  end

  describe "basic substitution (T-R1..T-R3)" do
    test "T-R1 a nil template renders to {:ok, nil}" do
      assert ServiceTask.render_body_template(nil, %{"x" => "y"}) == {:ok, nil}
    end

    test "T-R2 a static template (no placeholder, even non-JSON text) is returned verbatim" do
      assert ServiceTask.render_body_template("just plain text, not json", %{}) ==
               {:ok, "just plain text, not json"}

      assert ServiceTask.render_body_template(~s({"a": 1,}), %{}) == {:ok, ~s({"a": 1,})}
    end

    test "T-R2b a static template over the size cap passes unchecked (zero placeholders = byte-identical to pre-fix)" do
      big = String.duplicate("a", @size_cap + 4_000)
      assert ServiceTask.render_body_template(big, %{}) == {:ok, big}
    end

    test "T-R3 a placeholder inside a JSON string is replaced and the result decodes" do
      assert {:ok, rendered} =
               ServiceTask.render_body_template(
                 ~s({"r":"{{variables.reason}}"}),
                 %{"reason" => "abc"}
               )

      assert rendered == ~s({"r":"abc"})
      assert Jason.decode!(rendered) == %{"r" => "abc"}
    end

    test "T-R3b whitespace inside the braces is accepted; surrounding text is copied verbatim; two placeholders both substitute; non-variables braces stay literal" do
      template = ~s({"a":"x {{ variables.p }} y","b":"{{variables.q}}","c":"{{other}}"})

      assert {:ok, rendered} =
               ServiceTask.render_body_template(template, %{"p" => "P", "q" => "Q"})

      assert rendered == ~s({"a":"x P y","b":"Q","c":"{{other}}"})
    end

    test "T-R3c multi-byte template text before a placeholder does not shift the substitution offsets" do
      template = ~s({"ключ-é-日本":"{{variables.v}}","tail":"{{variables.w}}"})

      assert {:ok, rendered} =
               ServiceTask.render_body_template(template, %{"v" => "1", "w" => "2"})

      assert Jason.decode!(rendered) == %{"ключ-é-日本" => "1", "tail" => "2"}
    end

    test "T-R3d no re-expansion: a value that looks like a placeholder is inserted literally" do
      assert {:ok, rendered} =
               ServiceTask.render_body_template(
                 ~s({"r":"{{variables.tricky}}"}),
                 %{"tricky" => "{{variables.other}}", "other" => "SHOULD_NOT_APPEAR"}
               )

      assert Jason.decode!(rendered) == %{"r" => "{{variables.other}}"}
      refute rendered =~ "SHOULD_NOT_APPEAR"
    end
  end

  describe "escaping and injection (T-R4..T-R7)" do
    test "T-R4 a double quote in the value is escaped; the injection value cannot add a key" do
      assert {:ok, quoted} = render_r(~s(say "hi"))
      assert quoted == ~S({"r":"say \"hi\""})
      assert Jason.decode!(quoted) == %{"r" => ~s(say "hi")}

      assert {:ok, injected} = render_r(~s(x","admin":true))
      decoded = Jason.decode!(injected)
      assert Map.keys(decoded) == ["r"]
      refute Map.has_key?(decoded, "admin")
      assert decoded["r"] == ~s(x","admin":true)
    end

    test "T-R4b a structure-closing value cannot terminate the object or add array elements" do
      value = ~s(a"],"evil":["b)

      assert {:ok, rendered} =
               ServiceTask.render_body_template(
                 ~s({"list":["{{variables.v}}"],"k":1}),
                 %{"v" => value}
               )

      decoded = Jason.decode!(rendered)
      assert decoded |> Map.keys() |> Enum.sort() == ["k", "list"]
      assert decoded["list"] == [value]
    end

    test "T-R5 backslashes (including a trailing one) are doubled and round-trip" do
      value = "a" <> <<92>> <> "b" <> <<92>>
      assert {:ok, rendered} = render_r(value)
      assert rendered == "{\"r\":\"a" <> <<92, 92>> <> "b" <> <<92, 92>> <> "\"}"
      assert Jason.decode!(rendered) == %{"r" => value}
    end

    test "T-R6 control characters use the short escapes or uppercase hex escapes; no raw control byte remains" do
      value = "n\nt\tr\rb\bf\fz" <> <<0>> <> "u" <> <<0x1F>>
      assert {:ok, rendered} = render_r(value)

      for short <- [~S(\n), ~S(\t), ~S(\r), ~S(\b), ~S(\f)] do
        assert rendered =~ short
      end

      assert rendered =~ ~S(\u0000)
      assert rendered =~ ~S(\u001F)
      refute rendered =~ ~S(\u001f)
      refute Regex.match?(~r/[\x00-\x1f]/, rendered)
      assert Jason.decode!(rendered) == %{"r" => value}
    end

    test "T-R7a U+2028 and U+2029 become six-character ASCII escapes, never the raw codepoints" do
      value = "a" <> <<0x2028::utf8>> <> "b" <> <<0x2029::utf8>> <> "c"
      assert {:ok, rendered} = render_r(value)
      assert rendered =~ <<92>> <> "u2028"
      assert rendered =~ <<92>> <> "u2029"
      refute rendered =~ <<0x2028::utf8>>
      refute rendered =~ <<0x2029::utf8>>
      assert Jason.decode!(rendered) == %{"r" => value}
    end

    test "T-R7b a forward slash is NOT escaped" do
      assert {:ok, rendered} = render_r("a/b")
      assert rendered == ~S({"r":"a/b"})
      refute rendered =~ ~S(\/)
      assert Jason.decode!(rendered) == %{"r" => "a/b"}
    end

    test "T-R7c DEL (U+007F) passes through unchanged" do
      value = "a" <> <<0x7F>> <> "b"
      assert {:ok, rendered} = render_r(value)
      assert rendered =~ <<0x7F>>
      assert Jason.decode!(rendered) == %{"r" => value}
    end

    test "T-R7d angle brackets and ampersand are NOT escaped" do
      assert {:ok, rendered} = render_r("<a>&</a>")
      assert rendered == ~S({"r":"<a>&</a>"})
    end

    test "T-R7e emoji and non-Latin text stay as UTF-8 bytes and round-trip" do
      value = "Привет 日本語 😀"
      assert {:ok, rendered} = render_r(value)
      assert rendered == ~s({"r":"#{value}"})
      assert Jason.decode!(rendered) == %{"r" => value}
    end

    property "T-R7f any valid-UTF-8 value round-trips through render + decode as exactly one string field" do
      check all(
              value <-
                StreamData.one_of([
                  StreamData.string([0..0x7F]),
                  StreamData.string([0x2000..0x2100]),
                  StreamData.string(:printable)
                ]),
              max_runs: 200
            ) do
        assert {:ok, rendered} = render_r(value)
        assert Jason.decode!(rendered) == %{"r" => value}
      end
    end
  end

  describe "value types and missing variables (T-R8..T-R10)" do
    test "T-R8 map and list values land as ONE string holding compact JSON text, never a nested structure" do
      assert {:ok, rendered} = render_r(%{"a" => 1})
      assert Jason.decode!(rendered) == %{"r" => ~s({"a":1})}

      assert {:ok, rendered_list} = render_r([1, "x"])
      assert Jason.decode!(rendered_list) == %{"r" => ~s([1,"x"])}
    end

    test "T-R9 integers, floats and booleans stringify inside the quotes" do
      assert render_r(42) == {:ok, ~S({"r":"42"})}
      assert render_r(1.5) == {:ok, ~S({"r":"1.5"})}
      assert render_r(true) == {:ok, ~S({"r":"true"})}
      assert render_r(false) == {:ok, ~S({"r":"false"})}
    end

    test "T-R10 a present nil renders as the empty string; an absent key is a typed error" do
      assert render_r(nil) == {:ok, ~S({"r":""})}

      assert ServiceTask.render_body_template(~s({"r":"{{variables.k}}"}), %{}) ==
               {:error, {:missing_variable, "k"}}
    end
  end

  describe "placeholder position (T-R11, T-R12, T-R14, T-R15, T-R21)" do
    test "T-R11 a placeholder outside a JSON string is rejected without consulting the value" do
      # A tuple would yield :unsupported_value_type if the value were ever looked at.
      vars = %{"x" => {:never, :consulted}}

      assert ServiceTask.render_body_template(~s({"a": {{variables.x}}}), vars) ==
               {:error, :placeholder_outside_string}

      assert ServiceTask.render_body_template("{{variables.x}}", vars) ==
               {:error, :placeholder_outside_string}

      # a missing key outside a string is still the position error, not :missing_variable
      assert ServiceTask.render_body_template(~s({"a": {{variables.absent}}}), %{}) ==
               {:error, :placeholder_outside_string}
    end

    test "T-R12 an escaped quote before the placeholder keeps it inside the string; an escaped backslash does not" do
      inside = ~S({"r":"a\"{{variables.x}}"})
      assert {:ok, rendered} = ServiceTask.render_body_template(inside, %{"x" => "V"})
      assert rendered == ~S({"r":"a\"V"})
      assert Jason.decode!(rendered) == %{"r" => ~s(a"V)}

      outside = ~S({"r":"a\\"{{variables.x}}})

      assert ServiceTask.render_body_template(outside, %{"x" => "V"}) ==
               {:error, :placeholder_outside_string}
    end

    test "T-R14 a key-position placeholder can only change the key text, never the structure" do
      key = ~s(a","b":"c)

      assert {:ok, rendered} =
               ServiceTask.render_body_template(~s({"{{variables.k}}":1}), %{"k" => key})

      assert Jason.decode!(rendered) == %{key => 1}
    end

    test "T-R15 a malformed template that contains a placeholder is :rendered_body_not_json" do
      assert ServiceTask.render_body_template(~s({"r":"{{variables.x}}}), %{"x" => "V"}) ==
               {:error, :rendered_body_not_json}

      assert ServiceTask.render_body_template(~s({"r":"{{variables.x}}",}), %{"x" => "V"}) ==
               {:error, :rendered_body_not_json}
    end

    test "T-R21a a backslash OUTSIDE a string is ignored by the scan; the decode check decides" do
      template = <<92>> <> ~s({"r":"{{variables.x}}"})

      assert ServiceTask.render_body_template(template, %{"x" => "V"}) ==
               {:error, :rendered_body_not_json}
    end

    test "T-R21b first placeholder inside, second outside: position error, and the first value is never stringified" do
      template = ~s({"a":"{{variables.first}}","b":{{variables.second}}})
      vars = %{"first" => {:would, :not_stringify}, "second" => "S"}

      assert ServiceTask.render_body_template(template, vars) ==
               {:error, :placeholder_outside_string}
    end

    test "T-R21c a placeholder nested deep in objects and arrays is inside a string and substitutes" do
      assert {:ok, rendered} =
               ServiceTask.render_body_template(
                 ~s({"a":{"b":["{{variables.x}}"]}}),
                 %{"x" => "V"}
               )

      assert Jason.decode!(rendered) == %{"a" => %{"b" => ["V"]}}
    end
  end

  describe "size cap and typed value errors (T-R13, T-R16, T-R18)" do
    test "T-R13 exactly 65_536 rendered bytes passes; one more byte is :rendered_body_too_large" do
      assert {:ok, at_limit} = render_r(String.duplicate("a", @size_cap - @template_overhead))
      assert byte_size(at_limit) == @size_cap

      assert render_r(String.duplicate("a", @size_cap - @template_overhead + 1)) ==
               {:error, :rendered_body_too_large}
    end

    test "T-R16 invalid UTF-8 and unsupported terms are typed errors and never raise" do
      assert render_r(<<0xFF, 0xFE>>) == {:error, :invalid_utf8}
      assert render_r({1, 2}) == {:error, :unsupported_value_type}
      assert render_r(%{"nested" => {1, 2}}) == {:error, :unsupported_value_type}
      assert render_r(self()) == {:error, :unsupported_value_type}
    end

    test "T-R18 no error term contains the variable value" do
      secret = "S3CR3T-VALUE-xyz"

      errors = [
        render_r(secret <> <<0xFF>>),
        render_r({secret}),
        render_r(%{"k" => {secret}}),
        render_r(String.duplicate(secret, 10_000)),
        ServiceTask.render_body_template(~s({"r":"{{variables.v}}}), %{"v" => secret}),
        ServiceTask.render_body_template(~s({"r": {{variables.v}}}), %{"v" => secret}),
        ServiceTask.render_body_template(~s({"r":"{{variables.k}}"}), %{"v" => secret})
      ]

      for result <- errors do
        assert {:error, _reason} = result
        refute inspect(result, limit: :infinity, printable_limit: :infinity) =~ secret
      end
    end
  end

  describe "body_has_placeholders?/1 (T-R17)" do
    test "T-R17 nil and static are false; flat variables placeholders (with or without spaces) are true; other braces are false" do
      refute ServiceTask.body_has_placeholders?(nil)
      refute ServiceTask.body_has_placeholders?(~s({"a":1}))
      assert ServiceTask.body_has_placeholders?(~s({"a":"{{variables.x}}"}))
      assert ServiceTask.body_has_placeholders?(~s({"a":"{{ variables.x }}"}))
      refute ServiceTask.body_has_placeholders?(~s({"a":"{{other}}"}))
      refute ServiceTask.body_has_placeholders?(~s({"a":"{{variables.a.b}}"}))
    end
  end

  describe "error mapping (T-R19, T-R20)" do
    @sentences %{
      placeholder_outside_string:
        "service task body template could not be rendered: placeholder outside a JSON string",
      missing_variable:
        "service task body template could not be rendered: referenced variable is not set",
      invalid_utf8:
        "service task body template could not be rendered: variable value is not valid UTF-8",
      unsupported_value_type:
        "service task body template could not be rendered: variable value type is not supported",
      rendered_body_not_json:
        "service task body template could not be rendered: result is not valid JSON",
      rendered_body_too_large:
        "service task body template could not be rendered: result exceeds the size limit"
    }

    test "T-R19 build_body_render_error_attrs/1 yields the typed error with only the atom class and the fixed sentence" do
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()
      assert map_size(@sentences) == 6

      for {class, sentence} <- @sentences do
        attrs =
          ServiceTask.build_body_render_error_attrs(%{
            instance_id: instance_id,
            node_id: "svc",
            actor_id: actor_id,
            idempotency_key: "idem-1",
            variables: %{"review_id" => "r-1"},
            reason: class
          })

        assert attrs.error_type == :service_task_body_render_failed
        assert attrs.details == %{reason: class}
        assert attrs.reason == sentence
        assert attrs.affected == {:node, "svc"}
        assert attrs.instance_id == instance_id
        assert attrs.actor_id == actor_id
        assert attrs.idempotency_key == "idem-1"
        refute attrs.reason =~ "r-1"
        refute attrs.reason =~ "svc"
      end
    end

    test "T-R20 body_render_reason_class/1 is the identity on bare atoms and drops the key of :missing_variable" do
      for atom <- Map.keys(@sentences) -- [:missing_variable] do
        assert ServiceTask.body_render_reason_class(atom) == atom
      end

      assert ServiceTask.body_render_reason_class({:missing_variable, "k"}) == :missing_variable
    end
  end
end
