/// The four dedicated bootstrap-failure screens (REQ-421 design §6). Each
/// is reachable only via a `BootstrapFailureReason` dispatch — never a
/// generic error widget substituting for one of these four. Each carries a
/// fixed `Key` so tests can assert on presence without depending on text.
library;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';

const Key tenantNotFoundScreenKey = Key('tenant-not-found-screen');
const Key networkUnavailableScreenKey = Key('network-unavailable-screen');
const Key oidcFailureScreenKey = Key('oidc-failure-screen');
const Key secureStorageUnavailableScreenKey = Key(
  'secure-storage-unavailable-screen',
);

class TenantNotFoundScreen extends StatelessWidget {
  const TenantNotFoundScreen({super.key, this.onBackToEntry});

  /// Returns the user to the slug-entry screen — a not-found result means
  /// the slug itself was wrong, so retrying the same slug is not offered.
  final VoidCallback? onBackToEntry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: tenantNotFoundScreenKey,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('bootstrap.error.tenantNotFound.title')),
            Text(tr('bootstrap.error.tenantNotFound.body')),
            if (onBackToEntry != null)
              TextButton(
                onPressed: onBackToEntry,
                child: Text(tr('bootstrap.error.backToSignIn')),
              ),
          ],
        ),
      ),
    );
  }
}

class NetworkUnavailableScreen extends StatelessWidget {
  const NetworkUnavailableScreen({super.key, this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: networkUnavailableScreenKey,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('bootstrap.error.networkUnavailable.title')),
            Text(tr('bootstrap.error.networkUnavailable.body')),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: Text(tr('bootstrap.error.retry'))),
          ],
        ),
      ),
    );
  }
}

class OidcFailureScreen extends StatelessWidget {
  const OidcFailureScreen({super.key, this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: oidcFailureScreenKey,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('bootstrap.error.oidcFailure.title')),
            Text(tr('bootstrap.error.oidcFailure.body')),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: Text(tr('bootstrap.error.retry'))),
          ],
        ),
      ),
    );
  }
}

class SecureStorageUnavailableScreen extends StatelessWidget {
  const SecureStorageUnavailableScreen({super.key, this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: secureStorageUnavailableScreenKey,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('bootstrap.error.secureStorageUnavailable.title')),
            Text(tr('bootstrap.error.secureStorageUnavailable.body')),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: Text(tr('bootstrap.error.retry'))),
          ],
        ),
      ),
    );
  }
}
