// AC5 (parser half): the deep-link parser extracts a slug from a matching
// host and rejects any other host, returning no slug rather than guessing
// (REQ-421 design §1.1).
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

void main() {
  const platformHost = 'letflow.example';

  test('extracts the slug from a matching subdomain host', () {
    final uri = Uri.parse('https://acme.$platformHost/any/path');

    final slug = parseTenantSlugFromDeepLink(uri, platformHost: platformHost);

    expect(slug, 'acme');
  });

  test('path/query are irrelevant to slug extraction', () {
    final uri = Uri.parse(
      'https://acme.$platformHost/deeply/nested/path?x=1&y=2',
    );

    expect(
      parseTenantSlugFromDeepLink(uri, platformHost: platformHost),
      'acme',
    );
  });

  test('rejects a URL on a completely different host (no slug guessed)', () {
    final uri = Uri.parse('https://evil.example/acme');

    expect(
      parseTenantSlugFromDeepLink(uri, platformHost: platformHost),
      isNull,
    );
  });

  test('rejects the bare platform host with no subdomain', () {
    final uri = Uri.parse('https://$platformHost/');

    expect(
      parseTenantSlugFromDeepLink(uri, platformHost: platformHost),
      isNull,
    );
  });

  test('rejects a nested subdomain (more than one label)', () {
    final uri = Uri.parse('https://acme.staging.$platformHost/');

    expect(
      parseTenantSlugFromDeepLink(uri, platformHost: platformHost),
      isNull,
    );
  });

  test('rejects a non-https scheme (the OIDC redirect scheme is never routed'
      ' through this parser)', () {
    final uri = Uri.parse('com.bizdala.letflow:/oauth2redirect');

    expect(
      parseTenantSlugFromDeepLink(uri, platformHost: platformHost),
      isNull,
    );
  });

  test('rejects http (only https is accepted)', () {
    final uri = Uri.parse('http://acme.$platformHost/');

    expect(
      parseTenantSlugFromDeepLink(uri, platformHost: platformHost),
      isNull,
    );
  });

  test('never throws on a malformed/foreign URL', () {
    final uri = Uri.parse('https://not-the-platform-host.test/');

    expect(
      () => parseTenantSlugFromDeepLink(uri, platformHost: platformHost),
      returnsNormally,
    );
  });
}
