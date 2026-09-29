/// API: the `Dio`-backed HTTP client for Letflow's platform contract —
/// tenant-config, definitions, form/list/process/task calls —
/// `docs/mobile/architecture.md` §3. Built starting REQ-421/REQ-425.
///
/// The one place a `Dio` HTTP client instance is constructed, and the
/// tenant-config client, live in [api_client.dart], re-exported here so
/// `lib/api/` keeps one public entry point (REQ-421, MOB-2).
library;

export 'api_client.dart';
export 'api_error.dart';
