import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'i18n/i18n.dart';

/// Entry point only. No route table, no business logic — those live in
/// [app.dart] (the app widget + router) per REQ-419's design
/// (`lib/letflow/design/req419-mobile-scaffold.md` §3).
///
/// REQ-429 (MOB-7) design §3 — the ARB message catalogue is loaded once,
/// here, before `runApp`, and assigned to the global [appMessageCatalogue]
/// every widget's `tr(id)` call reads through. Loading it this early
/// means no widget ever observes the "not yet loaded" (empty) default.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  appMessageCatalogue = await MessageCatalogue.loadFromAssets();
  runApp(const ProviderScope(child: LetflowApp()));
}
