/// Test-only helper (REQ-429, MOB-7): loads the real ARB message catalogue
/// from assets and assigns it to the global [appMessageCatalogue], exactly
/// as `main()` does before `runApp` in production. A widget test that
/// pumps a screen rendering real translated text (via `tr(id)`) calls this
/// first; a widget test that never goes through app bootstrap otherwise
/// sees [appMessageCatalogue]'s empty default (every `tr(id)` call falls
/// back to the raw id), which is fine for tests that only assert on `Key`s.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/i18n/i18n.dart';

Future<void> loadTestMessageCatalogue() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  appMessageCatalogue = await MessageCatalogue.loadFromAssets();
}
