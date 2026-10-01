// Unit tests -- REQ-429 §4.4: date/number formatting wired to the tier-(a)
// formatting locale.
//
// AC4(a): date formatting differs between de-DE and en-US.
// AC4(b): number formatting differs between de-DE and en-US.
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:letflow/i18n/catalogue.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de-DE');
    await initializeDateFormatting('en-US');
  });

  test(
    'AC4a: localizedDateFormat renders a fixed date differently for de-DE vs en-US',
    () {
      final date = DateTime(2026, 3, 4);

      final de = localizedDateFormat('MMMM d, y', 'de-DE').format(date);
      final en = localizedDateFormat('MMMM d, y', 'en-US').format(date);

      expect(de, isNot(equals(en)));
      expect(de, contains('März'));
      expect(en, contains('March'));
    },
  );

  test(
    'AC4b: localizedDecimalFormat renders a fixed number differently for de-DE vs en-US '
    '(decimal-separator difference, per intl\'s own rules)',
    () {
      const number = 1234.5;

      final de = localizedDecimalFormat('de-DE').format(number);
      final en = localizedDecimalFormat('en-US').format(number);

      expect(de, isNot(equals(en)));
      expect(de, '1.234,5');
      expect(en, '1,234.5');
    },
  );
}
