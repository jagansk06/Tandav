/// Shared helpers for repositories: date/month formatting matching the
/// backend contract (ISO `YYYY-MM-DD` dates, `YYYY-MM-01` months).
library;

class DbFmt {
  static String date(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String month(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-01';

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