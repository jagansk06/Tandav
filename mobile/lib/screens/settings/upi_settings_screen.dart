import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../core/whatsapp.dart';
import '../../widgets/states.dart';

/// Owner-only UPI payment settings.
///
/// Holds the studio's UPI ID (VPA) and payee name. The VPA is what gets
/// embedded — as a tap-to-pay `upi://pay` link — into the fee-reminder WhatsApp
/// message, so a student can pay the studio's account from their own phone.
///
/// Like the fee-rule settings, this is stored in `app_settings`, which is
/// device-local and never synced/backed up (see the schema comment in
/// [TandavDatabase]).
class UpiSettingsScreen extends StatefulWidget {
  const UpiSettingsScreen({super.key});

  @override
  State<UpiSettingsScreen> createState() => _UpiSettingsScreenState();
}

class _UpiSettingsScreenState extends State<UpiSettingsScreen> {
  final _vpa = TextEditingController();
  final _payee = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loadFailed = false;
  bool _busy = false;
  String? _liveVpa;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _vpa.dispose();
    _payee.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final api = context.read<TandavApi>();
      final vpa = await api.getUpiVpa();
      final payee = await api.getUpiPayee();
      if (!mounted) return;
      _vpa.text = vpa ?? '';
      _payee.text = payee ?? '';
      _liveVpa = vpa;
    } on Exception {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final api = context.read<TandavApi>();
      final vpa = _vpa.text.trim();
      final payee = _payee.text.trim();
      await api.setUpiVpa(vpa);
      await api.setUpiPayee(payee);
      if (!mounted) return;
      _liveVpa = vpa.isEmpty ? null : vpa;
      Alert.show(
        context,
        vpa.isEmpty
            ? 'UPI payments turned off'
            : 'Saved — reminders will include the UPI pay link',
      );
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UPI / Payments')),
      body: _loadFailed
          ? ErrorView(
              message: 'Could not load settings',
              onRetry: () {
                setState(() => _loadFailed = false);
                _load();
              },
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 36),
              children: [
                _card(
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionHeader(title: 'Studio UPI details'),
                        const SizedBox(height: 8),
                        const Text(
                          'The UPI ID is added as a tap-to-pay link inside the '
                          'WhatsApp fee reminder, so a student can pay the '
                          'studio from their own phone.',
                          style: TextStyle(
                            color: TandavColors.textSecondary,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _vpa,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'UPI ID (VPA)',
                            hintText: 'tandav@okhdfcbank',
                            prefixIcon: Icon(Icons.qr_code_2_rounded),
                            helperText:
                                'The address students pay to. Leave blank to '
                                'disable UPI in reminders.',
                          ),
                          validator: (v) {
                            final t = v?.trim() ?? '';
                            if (t.isEmpty) return null;
                            return WhatsAppService.normalizeVpa(t) == null
                                ? 'Enter a valid UPI ID like name@bank'
                                : null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _payee,
                          decoration: const InputDecoration(
                            labelText: 'Payee name',
                            hintText: 'Tandav Studio',
                            prefixIcon: Icon(Icons.storefront_outlined),
                          ),
                        ),
                        const SizedBox(height: 18),
                        _busy
                            ? const Center(child: CircularProgressIndicator())
                            : GoldButton(
                                label: 'Save',
                                icon: Icons.check_rounded,
                                expanded: true,
                                onPressed: _save,
                              ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _LiveLinkCard(vpa: _liveVpa),
              ],
            ),
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        decoration: BoxDecoration(
          color: TandavColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: TandavColors.surfaceBorder),
        ),
        child: child,
      );
}

/// Live preview of the pay link that would be embedded in a reminder, built
/// from the currently *saved* VPA (not the unsaved text in the fields).
class _LiveLinkCard extends StatelessWidget {
  final String? vpa;
  const _LiveLinkCard({this.vpa});

  @override
  Widget build(BuildContext context) {
    final link = vpa == null
        ? null
        : WhatsAppService.upiPayLink(
            vpa: vpa!,
            amount: 100,
            note: 'Dance class fee',
          );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      decoration: BoxDecoration(
        color: TandavColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TandavColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Pay link preview'),
          const SizedBox(height: 8),
          if (link == null)
            const Text(
              'No UPI ID saved yet — reminders will not include a pay link '
              'until one is added above and saved.',
              style: TextStyle(
                color: TandavColors.textSecondary,
                fontSize: 12.5,
                height: 1.5,
              ),
            )
          else ...[
            const Text(
              'This is the link a parent can tap to jump straight to the '
              'payment screen for the same amount.',
              style: TextStyle(
                color: TandavColors.textSecondary,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 14),
            GoldButton(
              label: 'Tap to pay',
              icon: Icons.payments_outlined,
              expanded: true,
              onPressed: () => _launch(context, link),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link));
                  if (context.mounted) {
                    Alert.show(context, 'Payment link copied');
                  }
                },
                icon: const Icon(Icons.copy_rounded, size: 17),
                label: const Text('Copy link'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _launch(BuildContext context, String link) async {
    try {
      final ok = await launchUrl(
        Uri.parse(link),
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_self',
      );
      if (!ok && context.mounted) {
        Alert.show(context, 'No UPI app found on this device',
            isError: true);
      }
    } on Exception {
      if (context.mounted) {
        Alert.show(context, 'Could not open the payment link',
            isError: true);
      }
    }
  }
}
