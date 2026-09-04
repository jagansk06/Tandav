import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/event.dart';
import '../../widgets/states.dart';

class CostumePaymentSheet extends StatefulWidget {
  final EventParticipation participation;
  const CostumePaymentSheet({super.key, required this.participation});

  @override
  State<CostumePaymentSheet> createState() => _CostumePaymentSheetState();
}

class _CostumePaymentSheetState extends State<CostumePaymentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _due = TextEditingController();
  final _notesController = TextEditingController();
  bool _costumeRequired = true;
  bool _busy = false;

  static const _methods = ['cash', 'upi', 'card', 'bank_transfer', 'other'];
  String _method = 'cash';
  DateTime _date = DateTime.now();

  @override
  void initState() {
    super.initState();
    _costumeRequired = widget.participation.isCostumeRequired;
    if (widget.participation.dueValue != 0) {
      _due.text = widget.participation.dueValue.toStringAsFixed(2);
    }
    _notesController.text = widget.participation.notes ?? '';
  }

  @override
  void dispose() {
    _amount.dispose();
    _due.dispose();
    _notesController.dispose();
    super.dispose();
  }

  String get _iso =>
      '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final api = context.read<TandavApi>();
      final payload = <String, dynamic>{
        'is_costume_required': _costumeRequired,
        'notes': _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      };
      final dueVal = double.tryParse(_due.text.trim());
      if (dueVal != null && _costumeRequired) {
        payload['costume_fee_due'] = dueVal.toStringAsFixed(2);
      }
      final amt = double.tryParse(_amount.text.trim());
      if (amt != null && amt > 0) {
        payload['costume_fee_paid'] = amt.toStringAsFixed(2);
        payload['costume_paid_date'] = _iso;
        payload['costume_payment_method'] = _method;
      }
      await api.updateParticipation(widget.participation.id, payload);
      if (mounted) {
        Navigator.pop(context);
        Alert.show(context, 'Event fee updated');
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
    final p = widget.participation;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
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
                            'Event Fee',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                              color: TandavColors.textPrimary,
                            ),
                          ),
                          Text(
                            p.studentName,
                            style: const TextStyle(
                                fontSize: 13,
                                color: TandavColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    StatusBadge(status: p.costumeStatus),
                  ],
                ),
                const SizedBox(height: 14),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _costumeRequired,
                  title: const Text('Event fee required',
                      style: TextStyle(color: TandavColors.textPrimary)),
                  onChanged: (v) => setState(() => _costumeRequired = v),
                ),
                if (_costumeRequired) ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _due,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Total event fee (\u20B9)',
                      prefixIcon: Icon(Icons.checkroom_outlined),
                    ),
                    validator: (v) {
                      final d = double.tryParse(v ?? '');
                      if (d == null || d < 0) return 'Enter a valid amount';
                      return null;
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _amount,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Payment amount (\u20B9)',
                      prefixIcon: const Icon(Icons.currency_rupee_rounded),
                      suffixIcon: TextButton(
                        onPressed: () {
                          final d = double.tryParse(_due.text.trim());
                          if (d != null) {
                            _amount.text = (d - p.paidValue).toStringAsFixed(2);
                            setState(() {});
                          }
                        },
                        child: Text('Due ${Fmt.money(p.outstanding)}'),
                      ),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return null;
                      final amt = double.tryParse(v.trim());
                      if (amt == null || amt <= 0) {
                        return 'Enter a valid amount';
                      }
                      final due = double.tryParse(_due.text.trim()) ?? 0;
                      if (p.paidValue + amt > due + 0.001) {
                        return 'Payment exceeds total fee';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: _methods
                        .map((m) => ChoiceChip(
                              label: Text(m.toUpperCase()),
                              selected: _method == m,
                              onSelected: (_) => setState(() => _method = m),
                            ))
                        .toList(),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notesController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    prefixIcon: Icon(Icons.notes_rounded),
                  ),
                ),
                const SizedBox(height: 16),
                _busy
                    ? const Center(child: CircularProgressIndicator())
                    : GoldButton(
                        label: 'Save Event Fee Details',
                        icon: Icons.save_outlined,
                        expanded: true,
                        onPressed: _save,
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}