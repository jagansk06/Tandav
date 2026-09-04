import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../widgets/states.dart';

/// Owner-only settings for how monthly fees behave.
///
/// Today it holds one rule: the fixed rupee amount added to a month's fee when
/// the student did not pay the previous month's fee. The rule is applied
/// automatically at generation time and is never compounded onto itself — see
/// [FeeRepository].
class FeeSettingsScreen extends StatefulWidget {
  const FeeSettingsScreen({super.key});

  @override
  State<FeeSettingsScreen> createState() => _FeeSettingsScreenState();
}

class _FeeSettingsScreenState extends State<FeeSettingsScreen> {
  final _penalty = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loadFailed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _penalty.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await context.read<TandavApi>().getLateFeePenalty();
      if (!mounted) return;
      _penalty.text = p.toStringAsFixed(0);
    } on Exception {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final amount = double.parse(_penalty.text.trim());
      await context.read<TandavApi>().setLateFeePenalty(amount);
      if (!mounted) return;
      Alert.show(
        context,
        amount > 0
            ? 'Saved — ₹${amount.toStringAsFixed(0)} added to unpaid months'
            : 'Late-fee increment turned off',
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
      appBar: AppBar(title: const Text('Fee Settings')),
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
                        const SectionHeader(title: 'Late-fee increment'),
                        const SizedBox(height: 8),
                        const Text(
                          'If a student has not paid one month\'s fee, this '
                          'fixed amount is added to the next month\'s fee as an '
                          'increment.',
                          style: TextStyle(
                            color: TandavColors.textSecondary,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _penalty,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Increment amount (\u20B9)',
                            prefixIcon: Icon(Icons.currency_rupee_rounded),
                            helperText:
                                'Set 0 to turn the increment off',
                          ),
                          validator: (v) {
                            final amt = double.tryParse(v ?? '');
                            if (amt == null || amt < 0) {
                              return 'Enter a positive amount or 0';
                            }
                            return null;
                          },
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
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'How it works'),
                      const SizedBox(height: 8),
                      const _Bullet(
                          'Applied automatically when next month\'s fee record '
                          'is generated.'),
                      const _Bullet(
                          'Checked against the previous month: if that month '
                          'was not marked paid (due or partial), the increment '
                          'is added.'),
                      const _Bullet(
                          'Applied once per unpaid month — it never stacks onto '
                          'its own previous increment.'),
                      const _Bullet(
                          'Once the owner marks the unpaid month as paid, the '
                          'following month reverts to the normal monthly fee.'),
                      const _Bullet(
                          'A student only ever receives fee records from the '
                          'month they joined — the increment never applies to a '
                          'month before they were a student.'),
                    ],
                  ),
                ),
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

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5),
            child: Icon(Icons.check_circle_outline,
                size: 14, color: TandavColors.gold),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: TandavColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
