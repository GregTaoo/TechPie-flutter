import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/features/campus_card/presentation/localization/geekpay_localizations.dart';

void main() {
  final value = DateTime(2026, 9, 2, 3, 4, 5);

  test('formats complete localized timestamps', () {
    expect(
      const GeekPayLocalizations(Locale('zh')).fullDateTime(value),
      '2026-09-02 03:04:05',
    );
    expect(
      const GeekPayLocalizations(Locale('en')).fullDateTime(value),
      '09/02/2026 03:04:05',
    );
    expect(
      const GeekPayLocalizations(Locale('ja')).fullDateTime(value),
      '2026/09/02 03:04:05',
    );
  });

  test('formats date ranges with month and day only', () {
    final start = DateTime(2026, 9, 1);
    final end = DateTime(2026, 9, 2);
    expect(
      const GeekPayLocalizations(Locale('zh')).dateRangeDays(start, end),
      '9月1日 至 9月2日',
    );
    expect(
      const GeekPayLocalizations(Locale('en')).dateRangeDays(start, end),
      '09/01 to 09/02',
    );
    expect(
      const GeekPayLocalizations(Locale('ja')).dateRangeDays(start, end),
      '09/01〜09/02',
    );
  });
}
