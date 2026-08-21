import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'format.dart';

/// Result of attempting to open a WhatsApp chat.
enum WhatsAppOpenResult { launched, notInstalled, invalidNumber }

/// WhatsApp messaging helper for fee receipts and reminders.
///
/// Uses the standard WhatsApp deep-link mechanism —
/// `whatsapp://send?phone=<country_code_and_number>&text=<url_encoded_message>`
/// (the same intent behind the canonical `https://wa.me/<number>?text=...`
/// links) — so no WhatsApp Business API, Meta Cloud API or third-party
/// provider is involved. The admin still presses Send inside WhatsApp; this
/// feature never sends anything automatically.
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
  static String reminderMessage({
    required String studentName,
    required String monthLabel,
    required double amountDue,
  }) =>
      'Namaste $studentName, 🙏\n\n'
      'This is a gentle reminder from Tandav Studio regarding the '
      'monthly dance class fee for $monthLabel.\n\n'
      'Amount Due: ${_rupee(amountDue)}\n'
      'Status: Pending\n\n'
      'We kindly request you to complete the fee payment at your convenience.\n\n'
      'Thank you for your continued association with Tandav Studio. 🙏\n\n'
      'Regards,\nTandav Studio';

  /// Open WhatsApp with a pre-filled message for [number].
  ///
  /// The chat is launched directly via the WhatsApp deep link; the launch is
  /// attempted unconditionally and only reported as failed when the system
  /// genuinely cannot handle the intent (i.e. WhatsApp is not installed). A
  /// malformed number returns [WhatsAppOpenResult.invalidNumber].
  static Future<WhatsAppOpenResult> openChat({
    required String number,
    required String message,
  }) async {
    final normalized = normalizeIndianNumber(number);
    if (normalized == null) return WhatsAppOpenResult.invalidNumber;

    // Standard WhatsApp deep link. `phone` is the international number without
    // the leading '+', and `text` is URL-encoded for us by [Uri], so spaces,
    // line breaks, ₹, emojis and any other special characters survive the
    // query string intact.
    final uri = Uri(
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
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      return ok ? WhatsAppOpenResult.launched : WhatsAppOpenResult.notInstalled;
    } on Exception {
      return WhatsAppOpenResult.notInstalled;
    }
  }

  /// Format like the rest of the app (`₹ 1,000`) but without the space, so
  /// the message reads `₹1,000`.
  static String _rupee(num value) =>
      Fmt.money(value, exact: value % 1 != 0).replaceFirst('\u20B9 ', '\u20B9');
}
