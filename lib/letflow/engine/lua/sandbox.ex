defmodule Letflow.Engine.Lua.Sandbox do
  @moduledoc """
  REQ-151 (LUA-03, LUA-04 restated) — the single sandbox-construction entry point for
  tenant-supplied Lua script execution. Implements
  `lib/letflow/design/req151-lua-sandbox.md` exactly.

  `Sandbox.new/0` and `Sandbox.new/1` are the ONLY permitted call sites of `Lua.new/1`
  anywhere under `lib/` (INV-SBX-1). Every `Lua.t()` value reachable anywhere in this
  codebase that will run tenant-supplied script text MUST have been produced here, and by
  nothing else. This is enforced structurally (single call site), not by a runtime check.

  Construction never fails: there is no `{:ok, _} | {:error, _}` return shape for `new/0`
  or `new/1` (INV-SBX-4) — there is no external I/O, no config lookup, and no user input
  at construction time.

  ## LUA-03 restatement (design §7)

  This module restates R-Co's LUA-03 rather than satisfying its literal text, for three
  reasons:

  (a) `loadstring` is a Lua 5.1 name absent from Lua 5.3. The runtime this sandbox wraps
  (`tv-labs/lua`) implements Lua 5.3 only; there is no `loadstring` global to remove
  because Lua 5.3 never had one (renamed/merged into `load` upstream). Restated as a
  deny-set entry anyway, for literal-text completeness, though it denies nothing that
  could otherwise be reached.

  (b) `jit`, `ffi`, and `bit` do not exist in Lua 5.3 at all — they are LuaJIT-specific.
  R-Co's exclusion of them, including `ffi` (which R-Co's own `stdlib.zig` calls "a
  COMPLETE sandbox escape"), is vacuous under this runtime, not satisfied. No deny-set
  entry is added for them because there is nothing at those paths to deny and no library
  file installs them.

  (c) R-Co's SBX-1 invariant ("prune strictly AFTER open") does not transfer as a
  mechanism. `Lua.new/1` sandboxes by construction — the deny-set is applied while
  building the VM state, not by opening a full stdlib and pruning it afterward — so there
  is no open-then-prune ordering for this module to get right or wrong. The property
  SBX-1 protects (no window during which a denied global is reachable) still holds:
  every caller only ever observes a `Lua.t()` already returned by `Sandbox.new/0` or
  `Sandbox.new/1`; no intermediate construction state is ever exposed by this module's
  public API.

  `debug` is additional, not a fourth restatement reason — it is a gap in what the
  library's own default denies, not a gap in what LUA-03's text could name (R-Co's
  LUA-03 does name `debug` as MUST-NOT-load; this module actually satisfies that part of
  LUA-03's literal text where the library's un-amended default does not — see the
  deny-set below).

  ## LUA-04 restatement (design §8)

  This module restates R-Co's LUA-04 ("the sandbox MUST refuse to load Lua bytecode;
  only source text MAY be loaded") rather than satisfying it literally. The adopted
  runtime (`tv-labs/lua`) parses Lua source text only — it has no bytecode format, no
  bytecode loader, and therefore no bytecode-rejection code path to test. LUA-04 holds
  structurally: only source text can ever be loaded because nothing else is
  representable, not because a rejection check runs and returns an error. What this
  module's test suite verifies instead is the absence of every loader capable of
  consuming either form: `load`, `loadfile`, `dofile`, and `string.dump` — the last of
  which is doubly structural, since without a bytecode format there is also nothing for
  `string.dump` to serialize a function *into*, and indeed no such function is installed
  at all in this runtime.

  ## `coroutine` decision (design §6)

  `coroutine` does not exist in this Lua runtime at all — confirmed by reading
  `deps/lua/lib/lua/vm/stdlib.ex`'s installed library list and finding zero references
  to `"coroutine"` anywhere under `deps/lua/lib/`.

  No deny-set entry is added for `[:coroutine]`. Reason: `Lua.sandbox/2` works by
  overwriting a path with a raising function — calling it on a path that does not
  currently exist would CREATE a new global named `coroutine` (a callable that raises),
  where none exists today. That is the opposite of the intended effect: it manufactures
  a global surface rather than removing one, and a future reader diffing `pairs(_G)`
  against this module's deny-set could be misled into thinking `coroutine` is a real,
  sandboxed table rather than nothing at all. What is tested instead is that
  `coroutine == nil` from inside a `Sandbox.new/0` VM, proving the absence directly.

  If a future `tv-labs/lua` upgrade adds a `coroutine` library, the "coroutine is nil"
  test will start FAILING (not silently pass) — that failure is the intended trigger for
  revisiting this decision, and should be read as "the runtime changed a starting
  assumption," not as flakiness.

  ## No custom deny-set list (design §5 AC3 disposition)

  `new/1`'s `opts` do not expose a way for a caller to add or remove individual denied
  paths — the 28-entry deny-set below is fixed by this module. REQ-152 (LUA-14) is the
  requirement that extends this deny-set (the `os` time-surface functions); it consumes
  this module rather than constructing its own `Lua.t()`.

  ## The `:sandboxed`-replaces-defaults trap (design §5)

  `Lua.new/1`'s `sandboxed:` option is NOT merged with the library's own
  `@default_sandbox` — whatever list is passed IS the complete sandboxed set for that VM
  instance. Passing a partial list (e.g. calling the library directly with only
  `sandboxed: [[:os, :time]]`) would deny `os.time` and nothing else, silently reopening
  every other default denial. This module
  avoids that trap by never passing a partial list: the deny-set below restates every one
  of the library's 27 default paths explicitly in source (not by reference to
  `@default_sandbox`, so a future edit to the library's own default cannot silently
  change this module's behavior underneath it), plus this module's own addition
  (`[:debug]`), for a fixed 28-entry list every time.
  """

  @type deny_entry :: {path :: [atom()], reason :: String.t()}
  @type deny_set :: [deny_entry()]

  # 27 entries restated explicitly from `Lua.new/1`'s own `@default_sandbox`
  # (`deps/lua/lib/lua.ex`), verified against the ACTUAL installed Lua 5.3 stdlib
  # (`deps/lua/lib/lua/vm/stdlib*.ex`), not against documentation or R-Co's LuaJIT/5.1
  # module set. Several are "installed?  no" — vacuous, denying a path nothing occupies
  # — and are restated anyway for literal-text completeness with the library default and
  # with R-Co's LUA-03 text; each row says which case it is and why.
  @sandbox_deny_set [
    {[:io, :stdin],
     "Not installed: no `io` global exists anywhere in this runtime (no file installs a " <>
       "global named \"io\"; no Lua.VM.Stdlib.Io module exists). Vacuous, restated because " <>
       "R-Co's LUA-03 names `io` as a MUST-NOT-load module."},
    {[:io, :stdout], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :stderr], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :read], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :write], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :open], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :close], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :lines], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :popen], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :tmpfile], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :output], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :input], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :flush], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :type], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:file],
     "Not installed: no file handle type or global exists. Vacuous, same reasoning as " <>
       "`io.*` above — file-handle methods (`file:read`, etc.) have nothing to attach to " <>
       "since no `io.open` exists to produce a handle."},
    {[:os, :execute],
     "Not installed: `Lua.VM.Stdlib.Os` implements only clock/date/difftime/exit/" <>
       "getenv/setlocale/time/time_ms/time_us/tmpname — no `execute`. Vacuous; the " <>
       "strongest possible form of R-Co's \"if reachable, MUST remove\" for this path."},
    {[:os, :exit],
     "Installed (os_exit/2). Real denial — process-termination side effect must not be " <>
       "reachable from tenant script."},
    {[:os, :getenv], "Installed (os_getenv/2). Real denial — host environment disclosure."},
    {[:os, :remove],
     "Not installed: no `os_remove` function exists. Vacuous; filesystem mutation has " <>
       "nothing to attach to."},
    {[:os, :rename], "Not installed: no `os_rename` function exists. Same as `os.remove`."},
    {[:os, :tmpname],
     "Installed (os_tmpname/2). Real denial — filesystem path disclosure/creation."},
    {[:package],
     "Installed: `install_package_table/1` unconditionally sets a real `package` global " <>
       "table. Real denial — module-loading surface, not part of the MUST-load set " <>
       "(math, string, table)."},
    {[:load],
     "Installed (`base_globals/0` registers \"load\"). Real denial — dynamic source-text " <>
       "compilation from a runtime string, R-Co's LUA-03 explicit removal target."},
    {[:loadfile],
     "Not installed: no \"loadfile\" global is ever registered anywhere in this runtime. " <>
       "Vacuous; filesystem-backed load has nothing to attach to."},
    {[:require],
     "Installed (`base_globals/0` registers \"require\"). Real denial — module-loading " <>
       "surface, pairs with `package`."},
    {[:dofile],
     "Installed (`base_globals/0` registers \"dofile\"). Real denial — filesystem-backed " <>
       "execution."},
    {[:loadstring],
     "Not installed, and structurally cannot be: `loadstring` is a Lua 5.1 name; Lua 5.3 " <>
       "(this runtime's dialect) never had it. Restates LUA-03's literal text even though " <>
       "the name does not exist in this dialect (see moduledoc LUA-03(a))."},
    # Addition beyond `Lua.new/1`'s own `@default_sandbox` — this requirement's central
    # finding. `debug` is a real, installed global (`Lua.VM.Stdlib.Debug`, run
    # unconditionally for every `Lua.new/1` call) exposing `debug.getmetatable/1` and
    # `debug.setmetatable/2` (which bypass `__metatable` protection, per the library's
    # own moduledoc) and `debug.getupvalue/2` / `debug.setupvalue/3` (which read and
    # mutate a Lua closure's captured upvalues directly). This is a real, non-vacuous
    # sandbox gap in the library's own default sandbox that R-Co's LUA-03 (which never
    # opened `debug` at all) would have closed and that `Lua.new/1`'s defaults do not.
    {[:debug],
     "Installed, and NOT in Lua.new/1's own @default_sandbox. Metatable-protection " <>
       "bypass and arbitrary upvalue mutation are capabilities strictly beyond " <>
       "math/string/table's intended surface (LUA-03's MUST-load set) and are exactly " <>
       "the class of introspection primitive R-Co's stdlib.zig excluded by naming " <>
       "`debug` outright."}
  ]

  @doc "The full 28-entry deny-set: `{path, reason}` pairs, restated defaults plus `:debug`."
  @spec deny_set() :: deny_set()
  def deny_set, do: @sandbox_deny_set

  @doc """
  Builds a sandboxed `Lua.t()` with no construction-time options. Equivalent to
  `new([])`. See moduledoc for the deny-set, the `coroutine` decision, and the LUA-03/
  LUA-04 restatements this construction implements.
  """
  @spec new() :: Lua.t()
  def new, do: new([])

  @doc """
  Builds a sandboxed `Lua.t()`. `opts` currently defines no meaningful keys for this
  requirement — the parameter exists so later requirements (REQ-152, REQ-154..156) can
  extend behavior (e.g. `:max_instructions`) without ever constructing a `Lua.t()` via
  `Lua.new/1` directly. This is the ONLY permitted call site of `Lua.new/1` under `lib/`
  (INV-SBX-1). Construction never fails (INV-SBX-4).
  """
  @spec new(opts :: keyword()) :: Lua.t()
  def new(_opts) do
    sandboxed_paths = Enum.map(@sandbox_deny_set, fn {path, _reason} -> path end)
    Lua.new(sandboxed: sandboxed_paths)
  end
end
