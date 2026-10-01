import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/renderers/renderer_registry.dart';

import '../support/load_test_catalogue.dart';

void main() {
  setUpAll(loadTestMessageCatalogue);

  testWidgets(
    'RendererRegistry.build shows the unsupported-definition-type fallback '
    'for an unknown definition type, never an empty container',
    (tester) async {
      final registry = RendererRegistry();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) =>
                registry.build(context, 'not-a-real-type', const {}),
          ),
        ),
      );

      expect(find.byKey(unsupportedDefinitionTypeKey), findsOneWidget);
      expect(
        find.textContaining('Unsupported definition type'),
        findsOneWidget,
      );
    },
  );
}
