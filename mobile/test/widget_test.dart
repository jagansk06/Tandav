import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tandav_mobile/core/format.dart';
import 'package:tandav_mobile/core/theme.dart';
import 'package:tandav_mobile/widgets/states.dart';

void main() {
  testWidgets('tandav logo asset is bundled and loadable', (tester) async {
    final data =
        await rootBundle.load('assets/images/tandav_logo.jpeg');
    expect(data.lengthInBytes, greaterThan(0));
  });

  group('Fmt', () {
    test('money formats with ₹ prefix and Indian grouping', () {
      expect(Fmt.money(0), '₹ 0');
      expect(Fmt.money(1234), '₹ 1,234');
      expect(Fmt.money(123456.5), '₹ 1,23,457');
      expect(Fmt.money(null), '₹ 0');
    });

    test('monthLabel maps ISO month to "Mon Year"', () {
      expect(Fmt.monthLabel('2026-07'), 'Jul 2026');
      expect(Fmt.monthLabel('2026-7-1'), 'Jul 2026');
      expect(Fmt.monthLabel('garbage'), 'garbage');
      expect(Fmt.monthLabel(''), '');
    });

    test('date formats ISO date as dd/mm/yyyy', () {
      expect(Fmt.date('2026-08-09'), '09/08/2026');
      expect(Fmt.date(null), '—');
    });

    test('pct renders percentage', () {
      expect(Fmt.pct(85), '85.0%');
      expect(Fmt.pct(null), '—');
    });
  });

  testWidgets('EmptyView shows title and subtitle', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmptyView(
            icon: Icons.inbox_outlined,
            title: 'Nothing here',
            subtitle: 'Add something.',
          ),
        ),
      ),
    );
    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('Add something.'), findsOneWidget);
  });

  testWidgets('GoldButton renders label and disabled state', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GoldButton(
            label: 'Save',
            onPressed: null,
          ),
        ),
      ),
    );
    expect(find.text('Save'), findsOneWidget);
    final btn = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(btn.onPressed, isNull);
  });

  testWidgets('TandavTheme builds and has dark scaffold background',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: TandavTheme.dark, home: const Scaffold(body: SizedBox())),
    );
    final ctx = tester.element(find.byType(Scaffold));
    final bg = Theme.of(ctx).scaffoldBackgroundColor;
    expect(bg, TandavColors.background);
  });
}