import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/batch.dart';
import '../../models/event.dart';
import '../../widgets/states.dart';

class EventFormScreen extends StatefulWidget {
  final EventItem? event;
  const EventFormScreen({super.key, this.event});

  @override
  State<EventFormScreen> createState() => _EventFormScreenState();
}

class _EventFormScreenState extends State<EventFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.event?.name ?? '');
  late final _description =
      TextEditingController(text: widget.event?.description ?? '');
  late final _type =
      TextEditingController(text: widget.event?.eventType ?? '');
  late final _location =
      TextEditingController(text: widget.event?.location ?? '');
  DateTime _date = DateTime.now();
  int? _batchId;
  late Future<List<Batch>> _batchesFuture;
  bool _busy = false;

  bool get _isEdit => widget.event != null;

  @override
  void initState() {
    super.initState();
    _batchId = widget.event?.batchId;
    final d = widget.event?.eventDate;
    if (d != null) {
      final parsed = DateTime.tryParse(d);
      if (parsed != null) _date = parsed;
    }
    _batchesFuture = _loadBatches();
  }

  Future<List<Batch>> _loadBatches() async {
    final res = await context.read<TandavApi>().getBatches();
    return res.items;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _type.dispose();
    _location.dispose();
    super.dispose();
  }

  String get _iso =>
      '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final d = await pickDate(context, initial: _date);
    if (d != null) setState(() => _date = d);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final payload = {
      'name': _name.text.trim(),
      'description':
          _description.text.trim().isEmpty ? null : _description.text.trim(),
      'event_type': _type.text.trim(),
      'event_date': _iso,
      'location': _location.text.trim().isEmpty ? null : _location.text.trim(),
      'batch_id': _batchId,
    };
    try {
      final api = context.read<TandavApi>();
      if (_isEdit) {
        await api.updateEvent(widget.event!.id, payload);
      } else {
        await api.createEvent(payload);
      }
      if (!mounted) return;
      Alert.show(context, _isEdit ? 'Event updated' : 'Event created');
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
      appBar: AppBar(title: Text(_isEdit ? 'Edit Event' : 'New Event')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Event name *',
                prefixIcon: Icon(Icons.star_outline_rounded),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name is required' : null,
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickDate,
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Event date *',
                  prefixIcon: Icon(Icons.event_outlined),
                ),
                child: Text(
                  Fmt.date(_iso),
                  style: const TextStyle(color: TandavColors.textPrimary),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _type,
              decoration: const InputDecoration(
                labelText: 'Event type',
                hintText: 'e.g. Annual Day, Competition, Workshop',
                prefixIcon: Icon(Icons.category_outlined),
              ),
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
                    labelText: 'Batch (linked)',
                    prefixIcon: Icon(Icons.grid_view_outlined),
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('Open event (any student)'),
                    ),
                    ...batches.map(
                      (b) => DropdownMenuItem<int?>(
                        value: b.id,
                        child: Text(b.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() => _batchId = v),
                );
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _location,
              decoration: const InputDecoration(
                labelText: 'Location',
                prefixIcon: Icon(Icons.location_on_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _description,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Description',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 20),
            _busy
                ? const Center(child: CircularProgressIndicator())
                : GoldButton(
                    label: _isEdit ? 'Save Changes' : 'Create Event',
                    icon: _isEdit
                        ? Icons.save_outlined
                        : Icons.event_available_rounded,
                    expanded: true,
                    onPressed: _submit,
                  ),
          ],
        ),
      ),
    );
  }
}