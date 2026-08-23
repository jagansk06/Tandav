/// Shared helpers for repositories: date/month formatting matching the
/// backend contract (ISO `YYYY-MM-DD` dates, `YYYY-MM-01` months).
library;

class DbFmt {
  static String date(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String month(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-01';

  /// Normalize a month string to the first of that month (`YYYY-MM-01`).
  ///
  /// Accepts `2026-08`, `2026-08-17` and full ISO timestamps alike, and returns
  /// the month unchanged when it is already normalized. Anything unrecognisable
  /// is reported instead of being silently reinterpreted — a month that quietly
  /// changes value would corrupt the fee register for a whole month.
  static String monthStart(String month) {
    final match = RegExp(r'^(\d{4})-(\d{1,2})').firstMatch(month.trim());
    if (match == null) {
      throw RepoException('Invalid month "$month" (expected YYYY-MM)');
    }
    final m = int.parse(match.group(2)!);
    if (m < 1 || m > 12) {
      throw RepoException('Invalid month "$month" (month must be 01-12)');
    }
    return '${match.group(1)}-${m.toString().padLeft(2, '0')}-01';
  }

  static DateTime firstOfMonth(DateTime d) => DateTime(d.year, d.month, 1);

  static DateTime addMonths(DateTime d, int count) =>
      DateTime(d.year, d.month + count, 1);

  /// Monotonically increasing list of month starts from [start] (inclusive)
  /// through [end] (inclusive), capped to prevent runaway loops.
  static List<DateTime> monthsBetween(DateTime start, DateTime end, {int cap = 120}) {
    final from = firstOfMonth(start);
    final to = firstOfMonth(end);
    final out = <DateTime>[];
    var cursor = from;
    var guard = 0;
    while (!cursor.isAfter(to) && guard < cap) {
      out.add(cursor);
      cursor = addMonths(cursor, 1);
      guard++;
    }
    return out;
  }

  static double round2(num v) => (v * 100).roundToDouble() / 100;
}

class RepoException implements Exception {
  final String message;
  const RepoException(this.message);

  @override
  String toString() => message;
}