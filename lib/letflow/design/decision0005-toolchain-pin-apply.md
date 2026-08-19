# Design: apply decision 0005 — pin Elixir/OTP toolchain

Source: `docs/migration/decisions/0005-pin-formatting-toolchain.md`,
REVIEWER sign-off, option (a) + (b) backstop. Target: Elixir 1.18.3 / OTP 27.

## 1. `.tool-versions` (new file, repo root)

asdf's `elixir` plugin requires both a language-version line and a runtime
(`erlang`) line — the `elixir` line alone does not select an OTP version;
asdf resolves Elixir against whatever `erlang` entry is also present in the
same `.tool-versions`. Content (two lines, exact):

```
elixir 1.18.3-otp-27
erlang 27.2
```

Rationale for each token:
- `elixir 1.18.3-otp-27` — the `-otp-27` suffix is asdf-elixir's own
  convention for selecting a build compiled against the OTP 27 ABI; matches
  this host's live `elixir --version` output (`Elixir 1.18.3 (compiled with
  Erlang/OTP 27)`), captured directly, not inferred.
- `erlang 27.2` — **open question, not independently verified**: this host
  reports `erl -eval 'erlang:system_info(otp_release)'` → `"27"` and
  `erl -version` → `Erlang (SMP,ASYNC_THREADS) (BEAM) emulator version
  15.2.7.4`. `otp_release` only returns the major version, not the patch
  asdf needs, and `asdf` itself is not installed on this host (`asdf:
  command not found`), so the exact installable patch string could not be
  confirmed against asdf's own release list. `27.2` is the best available
  inference from the erts-15.2 series (erts 15.2.x ships with OTP 27.2.x)
  but ELIXIR-DEV must run `asdf list-all erlang | grep '^27\.'` (or check
  https://github.com/erlang/otp/releases) before writing this file and
  correct the patch if `27.2` is not what's actually installable/running.
  Do not silently keep `27.2` if that check shows a different patch.

## 2. `mix.exs` edit

Current (line 8):
```
elixir: "~> 1.14",
```
Change to:
```
elixir: "~> 1.18",
```
Not `== 1.18.3`: `mix.exs`'s `elixir:` requirement is a compile-time gate
checked on every `mix` invocation on every host, including hosts that
haven't yet run `asdf install` for the exact pinned patch. `~> 1.18` accepts
any `1.18.x`, so a host on `1.18.4` (a compatible patch release) still
compiles instead of being hard-rejected for no functional reason; the
decision record's own text distinguishes the *version-manager file*
(`.tool-versions`, exact pin, actively selects the toolchain) from the
*mix.exs requirement* (compile-time backstop, floor-with-ceiling only) —
tightening the ceiling to the minor version is what "tightened as a
compile-time backstop" means in the follow-on task text; an exact `==`
pin would conflate the two mechanisms and reintroduce option (a)'s
"blocked until exact patch installed" failure mode at the compile-time
layer, which the decision record does not ask for.

## 3. `README.md` edit

Current (`## Notes` section, lines 117–119):
```
- Elixir 1.14 / OTP 25 via apt was used to scaffold this — use whatever
  current version you have locally (1.17+ recommended) once you pull
  this down; nothing here depends on 1.14 specifically.
```
Replace with:
```
- Elixir 1.18.3 / OTP 27 is the pinned toolchain for this repo (see
  `docs/migration/decisions/0005-pin-formatting-toolchain.md`) — install
  it via `asdf install` after `asdf plugin add elixir` /
  `asdf plugin add erlang` if you don't already have those plugins; the
  root `.tool-versions` file selects the exact version automatically on
  `cd` into this repo. `mix.exs`'s `elixir: "~> 1.18"` requirement is a
  compile-time backstop only — it accepts any 1.18.x patch, so it will
  not itself catch formatter drift; running `mix format` (and
  `mix letflow.check`) under the `.tool-versions`-selected toolchain is
  what actually keeps formatting deterministic across hosts.
```

## Out of scope / not decided here

- Adding `.github/workflows` CI to enforce the pin mechanically — decision
  record explicitly defers this.
- The exact `erlang` patch in `.tool-versions` above is flagged as an open
  question ELIXIR-DEV must resolve before commit (see §1).
