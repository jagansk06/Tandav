import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/fee.dart';
import '../../widgets/states.dart';

class FeePaymentSheet extends StatefulWidget {
  final Fee fee;
  const FeePaymentSheet({super.key, required this.fee});

  @override
  State<FeePaymentSheet> createState() => _FeePaymentSheetState();
}

class _FeePaymentSheetState extends State<FeePaymentSheet> {
  final _amount = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String _method = 'cash';
  DateTime _date = DateTime.now();
  bool _busy = false;

  static const _methods = ['cash', 'upi', 'card', 'bank_transfer', 'other'];

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  String get _iso =>
      '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final api = context.read<TandavApi>();
      await api.recordFeePayment(
        widget.fee.id,
        double.parse(_amount.text.trim()),
        _iso,
        _method,
      );
      if (mounted) {
        Navigator.pop(context);
        Alert.show(context, 'Payment recorded');
      }
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
    final remaining = widget.fee.outstanding;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Record Payment',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                            color: TandavColors.textPrimary,
                          ),
                        ),
                        Text(
                          '${widget.fee.studentName} · ${Fmt.monthLabel(widget.fee.month)}',
                          style: const TextStyle(
                              fontSize: 13,
                              color: TandavColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: TandavColors.surfaceLight,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: TandavColors.surfaceBorder),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '${Fmt.money(widget.fee.paidValue)} paid',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: TandavColors.success,
                          ),
                        ),
                        Text(
                          '${Fmt.money(remaining)} due',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: TandavColors.yellow,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amount,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Amount (\u20B9)',
                  prefixIcon: const Icon(Icons.currency_rupee_rounded),
                  suffixIcon: TextButton(
                    onPressed: () {
                      _amount.text = remaining.toStringAsFixed(2);
                      setState(() {});
                    },
                    child: const Text('Full due'),
                  ),
                ),
                validator: (v) {
                  final amt = double.tryParse(v ?? '');
                  if (amt == null || amt <= 0) return 'Enter a valid amount';
                  if (amt > remaining + 0.001) {
                    return 'Cannot exceed remaining due of '
                        '${Fmt.money(remaining)}';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: _methods
                    .map(
                      (m) => ChoiceChip(
                        label: Text(m.toUpperCase()),
                        selected: _method == m,
                        onSelected: (_) => setState(() => _method = m),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final d = await pickDate(context, initial: _date);
                  if (d != null) setState(() => _date = d);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Payment date',
                    prefixIcon: Icon(Icons.event_outlined),
                  ),
                  child: Text(Fmt.date(_iso)),
                ),
              ),
              const SizedBox(height: 18),
              _busy
                  ? const Center(child: CircularProgressIndicator())
                  : GoldButton(
                      label: 'Confirm Payment',
                      icon: Icons.check_rounded,
                      expanded: true,
                      onPressed: _submit,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}