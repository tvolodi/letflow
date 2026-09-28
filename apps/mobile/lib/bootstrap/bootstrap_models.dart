/// Post-auth bootstrap response models and result types — REQ-421 design
/// §5.1/§5.2. Field names map 1:1 to `Letflow.Routers.Me`'s
/// `home_tenant_json/1`/`membership_json/1` (`lib/letflow/routers/me.ex`)
/// and `installed_module_json/1`.
library;

import 'package:flutter/foundation.dart' show immutable;

@immutable
class MembershipEntry {
  const MembershipEntry({
    required this.tenantId,
    required this.tenantSlug,
    required this.tenantDisplayName,
    required this.displayLabel,
  });

  final String tenantId;
  final String tenantSlug;
  final String tenantDisplayName;
  final String? displayLabel;

  factory MembershipEntry.fromJson(Map<String, dynamic> json) {
    return MembershipEntry(
      tenantId: json['tenant_id'] as String,
      tenantSlug: json['tenant_slug'] as String,
      tenantDisplayName: json['tenant_display_name'] as String,
      displayLabel: json['display_label'] as String?,
    );
  }
}

@immutable
class InstalledModule {
  const InstalledModule({required this.moduleId, required this.version});

  final String moduleId;
  final String version;

  factory InstalledModule.fromJson(Map<String, dynamic> json) {
    return InstalledModule(
      moduleId: json['module_id'] as String,
      version: json['version'] as String,
    );
  }
}

/// The four (and only four) failure buckets a bootstrap attempt can end in
/// (REQ-421 design §5.2, §6). A `null` `BootstrapResult` (see
/// `runTenantBootstrap`) is user cancellation — not one of these four, and
/// not a failure at all.
enum BootstrapFailureReason {
  tenantNotFound,
  networkUnavailable,
  oidcFailure,
  secureStorageUnavailable,
}

sealed class BootstrapResult {
  const BootstrapResult();
}

class BootstrapSuccess extends BootstrapResult {
  const BootstrapSuccess({required this.installedModules});

  final List<InstalledModule> installedModules;
}

class BootstrapFailure extends BootstrapResult {
  const BootstrapFailure(this.reason);

  final BootstrapFailureReason reason;
}
