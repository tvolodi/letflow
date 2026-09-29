/// Masked-reveal text: a masked-by-default display for a sensitive value
/// (an API key, a webhook signing key — `INV-4` material) that can be
/// revealed exactly once per controller instance, with no transition back
/// to masked-and-revealable (REQ-422 §7, MOB-5, BUILDS item 6, AC8).
library;

import 'package:flutter/material.dart';

/// The three states a [MaskRevealController] moves through, in one
/// direction only: `masked` -> `revealed` -> `locked`. There is no
/// transition from `locked` back to `revealed`.
enum MaskRevealPhase { masked, revealed, locked }

/// Drives a [MaskedRevealText]'s state. Exactly one reveal, ever, per
/// instance — a fresh [MaskRevealController] is the expected usage per
/// masked value; a screen showing N secrets constructs N controllers.
class MaskRevealController extends ChangeNotifier {
  MaskRevealController();

  MaskRevealPhase _phase = MaskRevealPhase.masked;

  /// The controller's current phase. Starts at [MaskRevealPhase.masked].
  MaskRevealPhase get phase => _phase;

  /// True iff the value may currently be revealed (i.e. still `masked`).
  bool get canReveal => _phase == MaskRevealPhase.masked;

  /// Moves `masked` -> `revealed`. A no-op (does not throw, does not
  /// notify) if already `revealed` or `locked` — a UI double-tap racing a
  /// hide transition must not crash the widget.
  void reveal() {
    if (_phase != MaskRevealPhase.masked) return;
    _phase = MaskRevealPhase.revealed;
    notifyListeners();
  }

  /// Moves `revealed` -> `locked`. A no-op if `masked` or already
  /// `locked`.
  void hide() {
    if (_phase != MaskRevealPhase.revealed) return;
    _phase = MaskRevealPhase.locked;
    notifyListeners();
  }
}

/// Displays [value] masked by default, revealable exactly once via
/// [controller]. Both [value] and [controller] are passed in **plaintext**
/// by the caller — this widget only controls *display*; it is not itself a
/// secret-fetching or secret-storage component.
class MaskedRevealText extends StatelessWidget {
  const MaskedRevealText({
    super.key,
    required this.value,
    required this.controller,
    this.maskCharacter = '•',
    this.style,
  });

  final String value;
  final MaskRevealController controller;
  final String maskCharacter;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final phase = controller.phase;
        final displayed = phase == MaskRevealPhase.revealed
            ? value
            : maskCharacter * value.length;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(displayed, style: style),
            const SizedBox(width: 8),
            _buildToggle(phase),
          ],
        );
      },
    );
  }

  Widget _buildToggle(MaskRevealPhase phase) {
    switch (phase) {
      case MaskRevealPhase.masked:
        return IconButton(
          icon: const Icon(Icons.visibility),
          onPressed: controller.reveal,
        );
      case MaskRevealPhase.revealed:
        return IconButton(
          icon: const Icon(Icons.visibility_off),
          onPressed: controller.hide,
        );
      case MaskRevealPhase.locked:
        return const IconButton(icon: Icon(Icons.visibility_off), onPressed: null);
    }
  }
}
