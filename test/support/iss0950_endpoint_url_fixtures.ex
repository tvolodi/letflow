defmodule Letflow.Iss0950EndpointUrlFixtures do
  @moduledoc """
  Shared URL tables for the ISS-0950 regression tests (catalog `endpoint_url`
  register/publish-time validation). Row ids match the test matrix in
  `lib/letflow/design/iss0950-catalog-endpoint-url-register-validation.md` §7;
  see `test/specs/ISS-0950.md`. Test-only support module (compiled via
  `elixirc_paths(:test)`), no behaviour of its own.
  """

  @doc "Rows that must be REJECTED, as `{matrix_id, url}`."
  @spec reject_urls() :: [{String.t(), String.t()}]
  def reject_urls do
    [
      {"R-HTTP", "http://example.test/x"},
      {"R-FTP", "ftp://example.test/x"},
      {"R-NOURL", "not a url"},
      {"R-SCHEMELESS", "example.test/x"},
      {"R-NOHOST", "https:///x"},
      {"R-LOOP4", "https://127.0.0.1/x"},
      {"R-META", "https://169.254.169.254/latest/meta-data"},
      {"R-RFC10", "https://10.0.0.5/"},
      {"R-RFC172-LOW", "https://172.16.0.1/"},
      {"R-RFC172-HIGH", "https://172.31.255.255/"},
      {"R-RFC192", "https://192.168.1.1/"},
      {"R-LOOP6", "https://[::1]/x"},
      {"R-ULA", "https://[fd00::1]/x"},
      {"R-LL6", "https://[fe80::1]/x"},
      {"R-MAPPED", "https://[::ffff:127.0.0.1]/x"},
      {"R-USERINFO", "https://good.example@127.0.0.1/x"},
      {"R-BARE-TPL", "{{variables.absent}}"},
      {"R-TPL-HOST", "https://{{variables.h}}/x"},
      {"R-TPL-SUBHOST", "https://api.{{variables.t}}.example.com/x"},
      {"R-TPL-PORT", "https://example.test:{{variables.p}}/x"},
      {"R-TPL-SCHEME", "{{variables.s}}://example.test/x"},
      {"R-TPL-NOSLASH", "https://example.test{{variables.p}}"},
      {"R-TPL-USERINFO", "https://{{variables.u}}@example.test/x"}
    ]
  end

  @doc "Rows that must be ACCEPTED, as `{matrix_id, url}`."
  @spec accept_urls() :: [{String.t(), String.t()}]
  def accept_urls do
    [
      {"A-PLAIN", "https://example.test/svc"},
      {"A-PORT", "https://example.test:8443/svc"},
      {"A-PUBIP", "https://203.0.113.10/svc"},
      {"A-172-OUT", "https://172.32.0.1/svc"},
      {"A-UPPER", "HTTPS://example.test/svc"},
      {"A-TPL-PATH", "https://example.test/iss0917/{{variables.region}}/svc"},
      {"A-TPL-QUERY", "https://example.test/svc?r={{variables.region}}"},
      {"A-TPL-FRAG", "https://example.test/svc\#{{variables.f}}"},
      {"A-TPL-SPACED", "https://example.test/{{ variables.region }}/x"},
      {"A-TPL-ONLYPATH", "https://example.test/{{variables.a}}{{variables.b}}"}
    ]
  end

  @doc "The exact error message the catalog changesets attach to `:endpoint_url`."
  @spec message() :: String.t()
  def message do
    "must be an https URL whose host is not a private, loopback or link-local address; template placeholders are allowed only after the host"
  end
end
