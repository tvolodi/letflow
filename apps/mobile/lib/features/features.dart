/// Features: per-module code, one subdirectory per module id
/// (`lib/features/<id>/`), mirroring `web/src/modules/<id>/`
/// (`docs/mobile/architecture.md` §6). No module code lives outside its
/// own `features/<id>/` subtree; `module_manifest.json` next to this file
/// declares each feature's `depends_on` list, enforced by
/// `test/guards/module_boundary_guard_test.dart`.
///
/// REQ-419 ships no modules yet — the manifest is empty. The first module
/// requirement populates both.
library;
