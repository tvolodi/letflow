import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// Entry point only. No route table, no business logic — those live in
/// [app.dart] (the app widget + router) per REQ-419's design
/// (`lib/letflow/design/req419-mobile-scaffold.md` §3).
void main() {
  runApp(const ProviderScope(child: LetflowApp()));
}
