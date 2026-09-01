// `kIsWeb` has to be imported explicitly. `material.dart` re-exports
// `widgets.dart`, which re-exports `foundation.dart` with only
// `show Brightness, UniqueKey` — so importing material does NOT bring it in.
// Same pattern as sync/drive_mailbox.dart.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'format.dart';

/// Result of attempting to open a WhatsApp chat.
enum WhatsAppOpenResult { launched, notInstalled, invalidNumber }

/// WhatsApp messaging helper for fee receipts and reminders.
///
/// Uses the standard WhatsApp deep-link mechanism — `whatsapp://send?...` on
/// Android, and the canonical `https://wa.me/<number>?text=...` form of the
/// same link in the browser, which is how the iPhone build ships. No WhatsApp
/// Business API, Meta Cloud API or third-party provider is involved. The admin
/// still presses Send inside WhatsApp; this feature never sends anything
/// automatically.
///
/// Opening a chat never touches the fee/student records in the database.
class WhatsAppService {
  /// WhatsApp brand green, used for the action buttons on the fee screen.
  static const accent = Color(0xFF25D366);

  /// Normalize an Indian mobile number into international form for wa.me:
  /// country code 91 followed by the 10-digit number.
  ///
  /// Accepts numbers stored as `9876543210`, `09876543210`, `+91 98765 43210`
  /// or `919876543210`. Returns `null` when the number is not a valid Indian
  /// mobile number. The stored value itself is never modified.
  static String? normalizeIndianNumber(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10 && _isIndian10(digits)) return '91$digits';
    if (digits.length == 11 && digits.startsWith('0')) {
      final body = digits.substring(1);
      if (_isIndian10(body)) return '91$body';
    }
    if (digits.length == 12 && digits.startsWith('91')) {
      final body = digits.substring(2);
      if (_isIndian10(body)) return '91$body';
    }
    return null;
  }

  /// 10-digit Indian mobile numbers start with 6–9.
  static bool _isIndian10(String digits) =>
      RegExp(r'^[6-9]\d{9}$').hasMatch(digits);

  /// Receipt message shown after a fee is marked PAID.
  static String receiptMessage({
    required String studentName,
    required String monthLabel,
    required double amount,
  }) =>
      'Namaste $studentName, 🙏\n\n'
      'This is to inform you that the monthly dance class fee for '
      '$monthLabel has been successfully received.\n\n'
      'Amount Paid: ${_rupee(amount)}\n'
      'Status: Paid ✓\n\n'
      'Thank you for being a valued member of Tandav Studio. '
      'We truly appreciate your continued association with us.\n\n'
      'Regards,\nTandav Studio';

  /// Reminder message shown while a fee is DUE (or partially paid).
  ///
  /// When [upiLink] is provided (a `upi://pay` deep link built for this
  /// student's fee), a short "Pay now" line is appended so the student can tap
  /// or scan straight to the payment from their own WhatsApp.
  static String reminderMessage({
    required String studentName,
    required String monthLabel,
    required double amountDue,
    String? upiLink,
  }) {
    final paymentLine = (upiLink != null && upiLink.isNotEmpty)
        ? '\n\nTap to pay now via UPI: $upiLink'
        : '';
    return 'Namaste $studentName, 🙏\n\n'
        'This is a gentle reminder from Tandav Studio regarding the '
        'monthly dance class fee for $monthLabel.\n\n'
        'Amount Due: ${_rupee(amountDue)}\n'
        'Status: Pending\n\n'
        'We kindly request you to complete the fee payment at your convenience.'
        '$paymentLine\n\n'
        'Thank you for your continued association with Tandav Studio. 🙏\n\n'
        'Regards,\nTandav Studio';
  }

  /// Absence notice sent to a student's guardian when the student was marked
  /// absent (or late) on a class day. A short, matter-of-fact message — the
  /// whole point is that the parent finds out promptly.
  static String absentMessage({
    required String studentName,
    required DateTime date,
    bool late = false,
  }) =>
      'Namaste, 🙏\n\n'
      'This is to inform you that '
      '${studentName.isEmpty ? 'your ward' : studentName} was '
      '${late ? 'late' : 'absent'} from today\'s dance class at Tandav Studio '
      '(${_dateLabel(date)}).\n\n'
      'Please let us know if there is anything we should be aware of.\n\n'
      'Regards,\nTandav Studio';

  static String _dateLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// Open WhatsApp with a pre-filled message for [number].
  ///
  /// The chat is launched directly via the WhatsApp deep link; the launch is
  /// attempted unconditionally and only reported as failed when the system
  /// genuinely cannot handle the intent (i.e. WhatsApp is not installed). A
  /// malformed number returns [WhatsAppOpenResult.invalidNumber].
  ///
  /// On the web [WhatsAppOpenResult.notInstalled] is effectively never
  /// returned; see the note on the return value below.
  static Future<WhatsAppOpenResult> openChat({
    required String number,
    required String message,
  }) async {
    final normalized = normalizeIndianNumber(number);
    if (normalized == null) return WhatsAppOpenResult.invalidNumber;

    // Two spellings of the same link, because a browser cannot use the first.
    //
    // Android keeps `whatsapp://send?phone=…&text=…`. `phone` is the
    // international number without the leading '+', and `text` is URL-encoded
    // for us by [Uri], so spaces, line breaks, ₹, emojis and any other special
    // characters survive the query string intact. `AndroidManifest.xml` already
    // declares this scheme under `<queries>`.
    //
    // The iPhone build gets `https://wa.me/<number>?text=…`. Safari will not
    // hand an unknown URL scheme from a web page off to another app, so
    // `whatsapp://` there does nothing whatsoever — no chat and no error, which
    // is the worst kind of broken. `wa.me` is an ordinary https link that iOS
    // recognises as belonging to WhatsApp and opens the app directly; with
    // WhatsApp absent it lands on WhatsApp's own page, which at least explains
    // itself.
    final uri = kIsWeb
        ? Uri.https('wa.me', '/$normalized', {'text': message})
        : Uri(
            scheme: 'whatsapp',
            host: 'send',
            queryParameters: {'phone': normalized, 'text': message},
          );

    // We deliberately do NOT gate the launch behind canLaunchUrl(): on some
    // devices (package-visibility / OEM restrictions, aggressive battery
    // optimizers) that probe reports a false negative even though WhatsApp is
    // installed, and it is precisely what produced the bogus "WhatsApp is not
    // installed" message. Instead we attempt the real launch and treat a
    // failure as the only reliable signal that WhatsApp is unavailable.
    try {
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
        // Web only, and it is what makes this work at all. With no window name
        // the plugin calls `window.open(url, '')` — a pop-up — and browsers
        // block pop-ups that are not the direct result of a tap. This one is
        // not: the caller loads the student from the database first, and that
        // await ends the user gesture. `_self` navigates the current page
        // instead, which is never blocked; iOS then hands the wa.me link to
        // WhatsApp, with Tandav still sitting behind it.
        webOnlyWindowName: kIsWeb ? '_self' : null,
      );
      // On the web `ok` is not evidence of anything: the plugin opens the
      // window with `noopener`, cannot observe the result, and returns true
      // unconditionally — verified in url_launcher_web 2.4.3, `openNewWindow`.
      // So "WhatsApp is not installed" is a message only Android can honestly
      // produce, and the browser simply navigates and lets the user see what
      // happened.
      return ok ? WhatsAppOpenResult.launched : WhatsAppOpenResult.notInstalled;
    } on Exception {
      return WhatsAppOpenResult.notInstalled;
    }
  }

  /// Format like the rest of the app (`₹ 1,000`) but without the space, so
  /// the message reads `₹1,000`.
  static String _rupee(num value) =>
      Fmt.money(value, exact: value % 1 != 0).replaceFirst('\u20B9 ', '\u20B9');

  /// Normalize an Indian UPI ID (VPA) to a clean, link-safe form. Accepts the
  /// usual spellings — `name@bank`, ` name@bank `, `upi://pay?...` pasted by
  /// mistake. Returns null when it is clearly not a VPA (no `@` with a non
  /// empty handle and non empty issuer).
  static String? normalizeVpa(String raw) {
    var v = raw.trim();
    // A pasted deep link is unwound back to its `pa=` parameter.
    final match = RegExp('[?&]pa=([^&]+)').firstMatch(v);
    if (match != null) v = Uri.decodeComponent(match.group(1)!).trim();
    final at = v.indexOf('@');
    if (at <= 0 || at == v.length - 1) return null;
    return v;
  }

  /// Build a `upi://pay` deep link that pre-fills a payment to the studio for
  /// this fee. Returns null when no UPI ID is configured. The link is what is
  /// embedded in the WhatsApp reminder; tapping it in WhatsApp on the student's
  /// phone opens their UPI app with the amount and a note identifying the
  /// student and month already filled in.
  static String? upiPayLink({
    required String vpa,
    String? payee,
    required double amount,
    required String note,
  }) {
    final normalized = normalizeVpa(vpa);
    if (normalized == null) return null;
    final params = <String, String>{
      'pa': normalized,
      if (payee != null && payee.isNotEmpty) 'pn': payee,
      'am': amount.toStringAsFixed(2),
      'cu': 'INR',
      'tn': note,
    };
    final q = params.entries
        .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return 'upi://pay?$q';
  }
}
