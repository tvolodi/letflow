// REQ-422 §7, MOB-5, AC8: masked-by-default, one-time reveal, cannot
// reveal a second time.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/design_system/design_system.dart';

void main() {
  testWidgets(
    'masked by default; reveal shows the real value; hide re-masks; a'
    ' second reveal attempt stays masked, never showing the real value'
    ' again',
    (tester) async {
      final controller = MaskRevealController();
      const secret = 'sk_live_ABC123';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MaskedRevealText(value: secret, controller: controller),
          ),
        ),
      );

      expect(find.text(secret), findsNothing);
      expect(find.text('•' * secret.length), findsOneWidget);
      expect(controller.phase, MaskRevealPhase.masked);
      expect(controller.canReveal, isTrue);

      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pump();

      expect(find.text(secret), findsOneWidget);
      expect(controller.phase, MaskRevealPhase.revealed);
      expect(controller.canReveal, isFalse);

      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pump();

      expect(find.text(secret), findsNothing);
      expect(find.text('•' * secret.length), findsOneWidget);
      expect(controller.phase, MaskRevealPhase.locked);

      // Attempt a second reveal directly (the icon may no longer be
      // present/enabled once locked) -- must stay masked, not the real
      // value.
      controller.reveal();
      await tester.pump();

      expect(controller.phase, MaskRevealPhase.locked);
      expect(find.text(secret), findsNothing);
      expect(find.text('•' * secret.length), findsOneWidget);
    },
  );

  test('MaskRevealController: reveal()/hide() no-ops do not throw and do'
      ' not notify listeners when called from the wrong phase', () {
    final controller = MaskRevealController();
    var notifyCount = 0;
    controller.addListener(() => notifyCount++);

    // hide() from masked: no-op.
    controller.hide();
    expect(controller.phase, MaskRevealPhase.masked);
    expect(notifyCount, 0);

    controller.reveal();
    expect(controller.phase, MaskRevealPhase.revealed);
    expect(notifyCount, 1);

    // reveal() again from revealed: no-op.
    controller.reveal();
    expect(controller.phase, MaskRevealPhase.revealed);
    expect(notifyCount, 1);

    controller.hide();
    expect(controller.phase, MaskRevealPhase.locked);
    expect(notifyCount, 2);

    // Both no-op from locked.
    controller.reveal();
    controller.hide();
    expect(controller.phase, MaskRevealPhase.locked);
    expect(notifyCount, 2);
  });
}
