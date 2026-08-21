import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/batch.dart';
import '../../models/student.dart';
import '../../widgets/states.dart';

class StudentFormScreen extends StatefulWidget {
  final Student? student;
  const StudentFormScreen({super.key, this.student});

  @override
  State<StudentFormScreen> createState() => _StudentFormScreenState();
}

class _StudentFormScreenState extends State<StudentFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _firstName = TextEditingController(text: widget.student?.firstName ?? '');
  late final _lastName = TextEditingController(text: widget.student?.lastName ?? '');
  late final _phone = TextEditingController(text: widget.student?.phone ?? '');
  late final _email = TextEditingController(text: widget.student?.email ?? '');
  late final _address = TextEditingController(text: widget.student?.address ?? '');
  late final _emergencyName =
      TextEditingController(text: widget.student?.emergencyContactName ?? '');
  late final _emergencyPhone =
      TextEditingController(text: widget.student?.emergencyContactPhone ?? '');
  late final _monthlyFee =
      TextEditingController(text: widget.student?.monthlyFee ?? '');
  late final _notes = TextEditingController(text: widget.student?.notes ?? '');

  String _gender = '';
  DateTime? _dob;
  DateTime _joinDate = DateTime.now();
  int? _batchId;
  bool _isActive = true;
  late Future<List<Batch>> _batchesFuture;
  bool _busy = false;

  bool get _isEdit => widget.student != null;

  @override
  void initState() {
    super.initState();
    final s = widget.student;
    _gender = s?.gender ?? '';
    final dob = s?.dob;
    _dob = dob != null ? DateTime.tryParse(dob) : null;
    final join = s?.joinDate;
    if (join != null) {
      final parsed = DateTime.tryParse(join);
      if (parsed != null) _joinDate = parsed;
    }
    _batchId = s?.batchId;
    _isActive = s?.isActive ?? true;
    _batchesFuture = _loadBatches();
  }

  Future<List<Batch>> _loadBatches() async {
    final res = await context.read<TandavApi>().getBatches();
    return res.items;
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _phone.dispose();
    _email.dispose();
    _address.dispose();
    _emergencyName.dispose();
    _emergencyPhone.dispose();
    _monthlyFee.dispose();
    _notes.dispose();
    super.dispose();
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  String? _phoneValidator(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    if (v.trim().length < 5) return 'Phone too short';
    return null;
  }

  String? _emailValidator(String? v) {
    if (v == null || v.isEmpty) return null;
    final pattern = RegExp(r'^[\w\.\-+]+@[\w\-]+(\.[\w\-]+)+$');
    return pattern.hasMatch(v.trim()) ? null : 'Enter a valid email';
  }

  String? _feeValidator(String? v) {
    final text = v?.trim() ?? '';
    if (text.isEmpty) return null;
    final amt = double.tryParse(text);
    if (amt == null || amt < 0) return 'Enter a valid amount';
    return null;
  }

  Future<void> _pickDob() async {
    final d = await pickDob(context, initial: _dob);
    if (d != null) setState(() => _dob = d);
  }

  Future<void> _pickJoinDate() async {
    final d = await pickDate(context, initial: _joinDate);
    if (d != null) setState(() => _joinDate = d);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final payload = {
      'first_name': _firstName.text.trim(),
      'last_name': _lastName.text.trim(),
      'gender': _gender,
      'dob': _dob != null
          ? '${_dob!.year.toString().padLeft(4, '0')}-${_dob!.month.toString().padLeft(2, '0')}-${_dob!.day.toString().padLeft(2, '0')}'
          : null,
      'phone': _phone.text.trim(),
      'email': _email.text.trim().isEmpty ? null : _email.text.trim(),
      'address': _address.text.trim().isEmpty ? null : _address.text.trim(),
      'emergency_contact_name':
          _emergencyName.text.trim().isEmpty ? null : _emergencyName.text.trim(),
      'emergency_contact_phone':
          _emergencyPhone.text.trim().isEmpty ? null : _emergencyPhone.text.trim(),
      'batch_id': _batchId,
      'monthly_fee': _monthlyFee.text.trim().isEmpty
          ? '0'
          : _monthlyFee.text.trim(),
      'join_date':
          '${_joinDate.year.toString().padLeft(4, '0')}-${_joinDate.month.toString().padLeft(2, '0')}-${_joinDate.day.toString().padLeft(2, '0')}',
      'is_active': _isActive,
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    };
    try {
      final api = context.read<TandavApi>();
      if (_isEdit) {
        await api.updateStudent(widget.student!.id, payload);
      } else {
        await api.createStudent(payload);
      }
      if (!mounted) return;
      Alert.show(context, _isEdit ? 'Student updated' : 'Student added');
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
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Student' : 'New Student'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _firstName,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'First name *',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
              validator: _required,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _lastName,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Last name'),
            ),
            const SizedBox(height: 12),
            // Gender
            Wrap(
              spacing: 8,
              children: ['', 'Female', 'Male', 'Other']
                  .map((g) => ChoiceChip(
                        label: Text(g.isEmpty ? 'Not set' : g),
                        selected: _gender == g,
                        onSelected: (_) => setState(() => _gender = g),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _pickDob,
                    borderRadius: BorderRadius.circular(12),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Date of birth',
                        prefixIcon: Icon(Icons.cake_outlined),
                      ),
                      child: Text(
                        _dob == null
                            ? 'Select date'
                            : Fmt.date(_dob!.toIso8601String()),
                        style: TextStyle(
                          color: _dob == null
                              ? TandavColors.textMuted
                              : TandavColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: _pickJoinDate,
                    borderRadius: BorderRadius.circular(12),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Join date *',
                        prefixIcon: Icon(Icons.event_outlined),
                      ),
                      child: Text(
                        Fmt.date(_joinDate.toIso8601String()),
                        style: const TextStyle(color: TandavColors.textPrimary),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone *',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              validator: _phoneValidator,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.mail_outline_rounded),
              ),
              validator: _emailValidator,
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<Batch>>(
              future: _batchesFuture,
              builder: (context, snapshot) {
                final batches = snapshot.data ?? [];
                return DropdownButtonFormField<int?>(
                  value: _batchId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Batch',
                    prefixIcon: Icon(Icons.grid_view_outlined),
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('No batch'),
                    ),
                    ...batches.map(
                      (b) => DropdownMenuItem<int?>(
                        value: b.id,
                        child: Text(
                          b.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() => _batchId = v),
                );
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _monthlyFee,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Monthly fee (\u20B9)',
                prefixIcon: Icon(Icons.currency_rupee_rounded),
                helperText:
                    'Recurring fee billed every month for this student',
              ),
              validator: _feeValidator,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _address,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Address',
                prefixIcon: Icon(Icons.home_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _emergencyName,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Emergency contact',
                      prefixIcon: Icon(Icons.emergency_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextFormField(
                    controller: _emergencyPhone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Contact phone',
                      prefixIcon: Icon(Icons.phone_forwarded_outlined),
                    ),
                  ),
                ),
              ],
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
                'Active student',
                style: TextStyle(color: TandavColors.textPrimary),
              ),
              onChanged: (v) => setState(() => _isActive = v),
            ),
            const SizedBox(height: 20),
            _busy
                ? const Center(child: CircularProgressIndicator())
                : GoldButton(
                    label: _isEdit ? 'Save Changes' : 'Add Student',
                    icon: _isEdit
                        ? Icons.save_outlined
                        : Icons.person_add_alt_1_rounded,
                    expanded: true,
                    onPressed: _submit,
                  ),
          ],
        ),
      ),
    );
  }
}