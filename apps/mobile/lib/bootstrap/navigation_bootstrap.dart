/// The one sanctioned navigation-bootstrap file: this is the single place
/// outside `lib/features/<id>/` permitted to import from inside a
/// feature's tree, because it is the file that reads the installed-module
/// list (`GET /api/v1/me/modules`) and wires the route table accordingly
/// (`docs/mobile/architecture.md` §6, decision `0039` D3, rule 1). Enforced
/// by `test/guards/module_boundary_guard_test.dart`, which special-cases
/// this exact path.
///
/// Also covers tenant slug/deep-link resolution and the app's startup
/// sequence (unauthenticated `tenant-config` fetch, then login) —
/// `docs/mobile/architecture.md` §1. Built starting REQ-421 (MOB-2).
///
/// This file is a placeholder tracked by git so the directory exists in
/// the tree shipped by REQ-419 (MOB-1 scaffold); it carries no logic yet.
library;
