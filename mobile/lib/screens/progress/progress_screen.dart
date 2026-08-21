import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/progress.dart';
import '../../widgets/states.dart';

class ProgressScreen extends StatefulWidget {
  final int? studentId;
  const ProgressScreen({super.key, this.studentId});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  late Future<ProgressListResponse> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = context.read<TandavApi>().getProgress(
          studentId: widget.studentId,
        );
    setState(() {});
  }

  Future<void> _editProgress(MonthlyProgress? existing) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: TandavColors.surface,
      isScrollControlled: true,
      builder: (_) => _ProgressSheet(
        studentId: widget.studentId,
        existing: existing,
      ),
    );
    if (result == null || !mounted) return;
    try {
      final api = context.read<TandavApi>();
      if (existing != null) {
        await api.updateProgress(
            existing.studentId, existing.month, result);
      } else {
        await api.createProgress(widget.studentId!, result);
      }
      if (!mounted) return;
      Alert.show(context,
          existing != null ? 'Progress updated' : 'Progress recorded');
      _reload();
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monthly Progress'),
        actions: [
          IconButton(
            onPressed: () => _editProgress(null),
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Record progress',
          ),
        ],
      ),
      body: FutureBuilder<ProgressListResponse>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingView(message: 'Loading progress…');
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: snapshot.error.toString(),
              onRetry: _reload,
            );
          }
          final items = snapshot.data!.items;
          if (items.isEmpty) {
            return EmptyView(
              icon: Icons.trending_up_rounded,
              title: 'No progress recorded',
              subtitle:
                  'Rate skill, performance and discipline for each month.',
              action: OutlinedButton.icon(
                onPressed: () => _editProgress(null),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Record First Progress'),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (ctx, i) => _card(items[i]),
          );
        },
      ),
    );
  }

  Widget _card(MonthlyProgress p) {
    final score = p.overallScore;
    final color = score >= 80
        ? TandavColors.success
        : score >= 60
            ? TandavColors.yellow
            : TandavColors.danger;
    final title = p.studentName.isEmpty
        ? Fmt.monthLabel(p.month)
        : '${p.studentName} · ${Fmt.monthLabel(p.month)}';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _editProgress(p),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        color: TandavColors.textPrimary,
                      ),
                    ),
                  ),
                  Container(
                    width: 54,
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '${score.toStringAsFixed(0)}',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: color,
                            height: 1,
                          ),
                        ),
                        const Text(
                          'OVERALL',
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            color: TandavColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _ratingRow('Skill', p.skillRating),
              _ratingRow('Performance', p.performanceRating),
              _ratingRow('Discipline', p.disciplineRating),
              _ratingRow(
                'Attendance',
                p.attendancePercentage?.round() ?? 0,
                isPercent: true,
              ),
              if ((p.remarks ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.notes_rounded,
                        size: 15, color: TandavColors.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        p.remarks!,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: TandavColors.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _ratingRow(String label, int value, {bool isPercent = false}) {
    final color = value >= 80
        ? TandavColors.success
        : value >= 60
            ? TandavColors.yellow
            : TandavColors.danger;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 12.5, color: TandavColors.textSecondary),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (value / 100).clamp(0, 1),
                minHeight: 6,
                backgroundColor: TandavColors.surfaceBorder,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 40,
            child: Text(
              isPercent ? '${value}%' : '$value',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressSheet extends StatefulWidget {
  final int? studentId;
  final MonthlyProgress? existing;
  const _ProgressSheet({this.studentId, this.existing});

  @override
  State<_ProgressSheet> createState() => _ProgressSheetState();
}

class _ProgressSheetState extends State<_ProgressSheet> {
  late DateTime _month = widget.existing != null
      ? DateTime.tryParse(widget.existing!.month) ?? DateTime.now()
      : DateTime.now();
  late final _skill = TextEditingController(
      text: widget.existing?.skillRating.toString() ?? '80');
  late final _performance = TextEditingController(
      text: widget.existing?.performanceRating.toString() ?? '80');
  late final _discipline = TextEditingController(
      text: widget.existing?.disciplineRating.toString() ?? '80');
  late final _remarks = TextEditingController(
      text: widget.existing?.remarks ?? '');
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;

  @override
  void dispose() {
    _skill.dispose();
    _performance.dispose();
    _discipline.dispose();
    _remarks.dispose();
    super.dispose();
  }

  String get _iso =>
      '${_month.year.toString().padLeft(4, '0')}-${_month.month.toString().padLeft(2, '0')}-01';

  String? _ratingValidator(String? v) {
    final n = int.tryParse(v ?? '');
    if (n == null || n < 0 || n > 100) {
      return '0 - 100';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    Future<void> pickMonth() async {
      final picked = await showDatePicker(
        context: context,
        initialDate: _month,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
        helpText: 'Select month',
      );
      if (picked != null) setState(() => _month = picked);
    }

    void submit() {
      if (!_formKey.currentState!.validate() || _busy) return;
      setState(() => _busy = true);
      Navigator.pop(context, {
        'month': _iso,
        'skill_rating': int.parse(_skill.text.trim()),
        'performance_rating': int.parse(_performance.text.trim()),
        'discipline_rating': int.parse(_discipline.text.trim()),
        'remarks': _remarks.text.trim().isEmpty ? null : _remarks.text.trim(),
      });
    }

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Record Monthly Progress',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: TandavColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 14),
                InkWell(
                  onTap: pickMonth,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Month',
                      prefixIcon: Icon(Icons.calendar_month_outlined),
                    ),
                    child: Text(Fmt.monthLabel(_iso)),
                  ),
                ),
                const SizedBox(height: 12),
                for (final (label, controller, icon, hint) in [
                  ('Skill rating (0-100)', _skill,
                      Icons.self_improvement_rounded, 'Technique & steps'),
                  ('Performance rating (0-100)', _performance,
                      Icons.theater_comedy_outlined, 'Stage & expression'),
                  ('Discipline rating (0-100)', _discipline,
                      Icons.handshake_outlined, 'Punctual & focused'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextFormField(
                      controller: controller,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: label,
                        hintText: hint,
                        prefixIcon: Icon(icon),
                        suffixIcon: IconButton(
                          onPressed: () =>
                              controller.text = '80',
                          icon: const Icon(Icons.tag_rounded, size: 18),
                          tooltip: 'Set 80',
                        ),
                      ),
                      validator: _ratingValidator,
                    ),
                  ),
                TextFormField(
                  controller: _remarks,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Remarks',
                    hintText: 'Monthly feedback for the student',
                    prefixIcon: Icon(Icons.notes_rounded),
                  ),
                ),
                const SizedBox(height: 16),
                _busy
                    ? const Center(child: CircularProgressIndicator())
                    : GoldButton(
                        label: widget.existing != null
                            ? 'Update Progress'
                            : 'Save Progress',
                        icon: Icons.save_outlined,
                        expanded: true,
                        onPressed: submit,
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}