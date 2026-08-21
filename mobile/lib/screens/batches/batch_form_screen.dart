import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/batch.dart';
import '../../widgets/states.dart';

class BatchFormScreen extends StatefulWidget {
  final Batch? batch;
  const BatchFormScreen({super.key, this.batch});

  @override
  State<BatchFormScreen> createState() => _BatchFormScreenState();
}

class _BatchFormScreenState extends State<BatchFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.batch?.name ?? '');
  late final _style =
      TextEditingController(text: widget.batch?.danceStyle ?? '');
  late final _level = TextEditingController(text: widget.batch?.level ?? '');
  late final _schedule =
      TextEditingController(text: widget.batch?.schedule ?? '');
  late final _fee = TextEditingController(text: widget.batch?.monthlyFee ?? '');
  late final _notes = TextEditingController(text: widget.batch?.notes ?? '');
  bool _isActive = true;
  bool _busy = false;

  bool get _isEdit => widget.batch != null;

  @override
  void initState() {
    super.initState();
    _isActive = widget.batch?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _style.dispose();
    _level.dispose();
    _schedule.dispose();
    _fee.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final payload = {
      'name': _name.text.trim(),
      'dance_style': _style.text.trim(),
      'level': _level.text.trim(),
      'schedule': _schedule.text.trim(),
      'monthly_fee': _fee.text.trim().isEmpty ? '0' : _fee.text.trim(),
      'is_active': _isActive,
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    };
    try {
      final api = context.read<TandavApi>();
      if (_isEdit) {
        await api.updateBatch(widget.batch!.id, payload);
      } else {
        await api.createBatch(payload);
      }
      if (!mounted) return;
      Alert.show(context, _isEdit ? 'Batch updated' : 'Batch created');
      Navigator.pop(context);
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
      appBar: AppBar(title: Text(_isEdit ? 'Edit Batch' : 'New Batch')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Batch name *',
                prefixIcon: Icon(Icons.grid_view_outlined),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name is required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _style,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Dance style',
                hintText: 'e.g. Bharatanatyam, Kathak, Bollywood',
                prefixIcon: Icon(Icons.self_improvement_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _level,
              decoration: const InputDecoration(
                labelText: 'Level',
                hintText: 'e.g. Beginner, Intermediate, Advanced',
                prefixIcon: Icon(Icons.signal_cellular_alt_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _schedule,
              decoration: const InputDecoration(
                labelText: 'Schedule',
                hintText: 'e.g. Mon/Wed 5:00-6:30 PM',
                prefixIcon: Icon(Icons.schedule_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _fee,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Monthly fee (\u20B9)',
                prefixIcon: Icon(Icons.currency_rupee_rounded),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                final f = double.tryParse(v.trim());
                if (f == null || f < 0) return 'Enter a valid amount';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Notes',
                prefixIcon: Icon(Icons.notes_rounded),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isActive,
              activeTrackColor: TandavColors.gold.withValues(alpha: 0.4),
              title: const Text(
                'Active batch',
                style: TextStyle(color: TandavColors.textPrimary),
              ),
              onChanged: (v) => setState(() => _isActive = v),
            ),
            const SizedBox(height: 20),
            _busy
                ? const Center(child: CircularProgressIndicator())
                : GoldButton(
                    label: _isEdit ? 'Save Changes' : 'Create Batch',
                    icon: _isEdit
                        ? Icons.save_outlined
                        : Icons.grid_view_rounded,
                    expanded: true,
                    onPressed: _submit,
                  ),
          ],
        ),
      ),
    );
  }
}