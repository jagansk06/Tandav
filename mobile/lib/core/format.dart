import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';

class Fmt {
  static final _money = NumberFormat.currency(
      locale: 'en_IN', symbol: '\u20B9 ', decimalDigits: 0);
  static final _moneyExact = NumberFormat.currency(
      locale: 'en_IN', symbol: '\u20B9 ', decimalDigits: 2);

  static String money(num? value, {bool exact = false}) =>
      value == null ? '\u20B9 0' : (exact ? _moneyExact.format(value) : _money.format(value));

  static String date(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final parts = iso.split('T').first.split('-');
    if (parts.length != 3) return iso;
    return '${parts[2]}/${parts[1]}/${parts[0]}';
  }

  static String monthLabel(String iso) {
    final parts = iso.split('-');
    if (parts.length < 2) return iso;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final m = int.tryParse(parts[1]);
    return m != null && m >= 1 && m <= 12 ? '${months[m - 1]} ${parts[0]}' : iso;
  }

  static String pct(num? value) => value == null ? '—' : '${value.toStringAsFixed(1)}%';
}

class Alert {
  static void show(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.check_circle_outline,
                color: isError ? TandavColors.danger : TandavColors.success,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      );
  }
}

Future<DateTime?> pickDate(BuildContext context, {DateTime? initial}) async {
  final picked = await showDatePicker(
    context: context,
    initialDate: initial ?? DateTime.now(),
    firstDate: DateTime(2020),
    lastDate: DateTime(2100),
  );
  return picked;
}

/// Date-of-birth picker: any date from 01/01/1980 through 31/12/2030.
Future<DateTime?> pickDob(BuildContext context, {DateTime? initial}) async {
  final clamped = switch (initial) {
    null => DateTime(2010),
    final d when d.isBefore(DateTime(1980, 1, 1)) => DateTime(1980, 1, 1),
    final d when d.isAfter(DateTime(2030, 12, 31)) => DateTime(2030, 12, 31),
    _ => initial,
  };
  final picked = await showDatePicker(
    context: context,
    initialDate: clamped,
    firstDate: DateTime(1980, 1, 1),
    lastDate: DateTime(2030, 12, 31),
  );
  return picked;
}