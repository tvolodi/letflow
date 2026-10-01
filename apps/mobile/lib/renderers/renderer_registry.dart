import 'package:flutter/material.dart';

import '../i18n/i18n.dart';

/// Builds the widget for a server-delivered definition of a given type.
///
/// [definition] is the raw JSON definition payload as decoded from the
/// server response — renderers registered against a given
/// `definitionType` are responsible for interpreting their own shape.
typedef DefinitionWidgetBuilder =
    Widget Function(BuildContext context, Map<String, dynamic> definition);

/// Key found by widget tests asserting the unsupported-definition-type
/// fallback is shown (never an empty container) — MOB-4's stale-version
/// principle, applied from day one (REQ-419 §4).
const Key unsupportedDefinitionTypeKey = Key('unsupported-definition-type');

/// A registry of [DefinitionWidgetBuilder]s keyed by definition-type
/// string (e.g. `"form"`, `"list"`, `"process"`, `"task"`).
///
/// REQ-419 ships this registry with zero entries registered — the four
/// renderer kinds are built by REQ-426..428. Looking up an unregistered
/// (or simply unknown/future) definition type always falls back to
/// [UnsupportedDefinitionTypeWidget] rather than throwing or rendering
/// nothing, so a stale client fails loudly instead of showing a blank
/// screen.
class RendererRegistry {
  final Map<String, DefinitionWidgetBuilder> _builders = {};

  /// Registers (or overwrites) the builder for [definitionType].
  void register(String definitionType, DefinitionWidgetBuilder builder) {
    _builders[definitionType] = builder;
  }

  /// Builds the widget for [definitionType] and [definition]. Falls back
  /// to [UnsupportedDefinitionTypeWidget] when no builder is registered
  /// for [definitionType].
  Widget build(
    BuildContext context,
    String definitionType,
    Map<String, dynamic> definition,
  ) {
    final builder = _builders[definitionType];
    if (builder == null) {
      return UnsupportedDefinitionTypeWidget(definitionType: definitionType);
    }
    return builder(context, definition);
  }
}

/// Explicit fallback shown for a definition type the app cannot render —
/// never an empty `Container()`/`SizedBox.shrink()`. See
/// `docs/mobile/architecture.md` §5 and `MOB-4`'s six mandatory renderer
/// states.
class UnsupportedDefinitionTypeWidget extends StatelessWidget {
  const UnsupportedDefinitionTypeWidget({
    super.key,
    required this.definitionType,
  });

  final String definitionType;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: unsupportedDefinitionTypeKey,
      child: Text(
        '${tr('renderer.unsupportedDefinitionType')}: $definitionType',
      ),
    );
  }
}
