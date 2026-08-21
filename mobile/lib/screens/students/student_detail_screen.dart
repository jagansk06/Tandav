import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/attendance.dart';
import '../../models/fee.dart';
import '../../models/progress.dart';
import '../../models/student.dart';
import '../../widgets/states.dart';
import '../fees/fee_payment_sheet.dart';
import '../progress/progress_screen.dart';
import 'student_form_screen.dart';

class StudentDetailScreen extends StatefulWidget {
  final int studentId;
  const StudentDetailScreen({super.key, required this.studentId});

  @override
  State<StudentDetailScreen> createState() => _StudentDetailScreenState();
}

class _StudentDetailScreenState extends State<StudentDetailScreen> {
  late Future<Student> _studentFuture;
  late Future<List<MonthlyAttendanceSummary>> _attendanceFuture;
  late Future<ProgressListResponse> _progressFuture;
  late Future<FeeListResponse> _feesFuture;
  late Future<List<Map<String, dynamic>>> _paymentsFuture;

  String _month = '${DateTime.now().year.toString()}-${DateTime.now().month.toString().padLeft(2, '0')}-01';
  int? _busyFeeId;

  @override
  void initState() {
    super.initState();
    _studentFuture = context.read<TandavApi>().getStudent(widget.studentId);
    _attendanceFuture =
        context.read<TandavApi>().getMonthlyAttendance(_month);
    _feesFuture = context.read<TandavApi>().getFees(studentId: widget.studentId);
    _paymentsFuture = context.read<TandavApi>().paymentHistory(widget.studentId);
    _progressFuture =
        context.read<TandavApi>().studentProgressHistory(widget.studentId);
  }

  void _reloadAll() {
    setState(() {
      _studentFuture = context.read<TandavApi>().getStudent(widget.studentId);
      _attendanceFuture =
          context.read<TandavApi>().getMonthlyAttendance(_month);
      _feesFuture =
          context.read<TandavApi>().getFees(studentId: widget.studentId);
      _paymentsFuture =
          context.read<TandavApi>().paymentHistory(widget.studentId);
      _progressFuture =
          context.read<TandavApi>().studentProgressHistory(widget.studentId);
    });
  }

  Future<void> _pickAndUploadPhoto() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 82,
    );
    if (image == null) return;
    try {
      final file = File(image.path);
      final api = context.read<TandavApi>();
      await api.uploadPhoto(widget.studentId, file, 'photo.jpg');
      if (!mounted) return;
      Alert.show(context, 'Photo updated');
      _reloadAll();
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    }
  }

  Future<void> _delete() async {
    final api = context.read<TandavApi>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TandavColors.surface,
        title: const Text('Delete student?'),
        content: const Text(
            'This permanently removes the student and all related records.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete',
                style: TextStyle(color: TandavColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await api.deleteStudent(widget.studentId);
      if (mounted) {
        Navigator.pop(context);
        Alert.show(context, 'Student deleted');
      }
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
        title: const Text('Student Profile'),
        actions: [
          IconButton(
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline_rounded),
            color: TandavColors.danger,
          ),
        ],
      ),
      body: FutureBuilder<Student>(
        future: _studentFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingView(message: 'Loading profile…');
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: snapshot.error.toString(),
              onRetry: _reloadAll,
            );
          }
          final student = snapshot.data!;
          return RefreshIndicator(
            onRefresh: () async => _reloadAll(),
            color: TandavColors.gold,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                _header(student),
                const SizedBox(height: 14),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        _infoRow(Icons.grid_view_outlined, 'Batch',
                            student.batchName ?? 'No batch'),
                        _infoRow(Icons.currency_rupee_rounded, 'Monthly Fee',
                            Fmt.money(double.tryParse(student.monthlyFee) ?? 0)),
                        _infoRow(Icons.phone_outlined, 'Phone', student.phone),
                        _infoRow(Icons.mail_outline_rounded, 'Email',
                            student.email ?? '—'),
                        _infoRow(Icons.cake_outlined, 'Date of birth',
                            Fmt.date(student.dob)),
                        _infoRow(Icons.event_outlined, 'Joined',
                            Fmt.date(student.joinDate)),
                        if ((student.emergencyContactName ?? '').isNotEmpty)
                          _infoRow(
                              Icons.emergency_outlined,
                              'Emergency contact',
                              '${student.emergencyContactName ?? '—'}'
                              '${student.emergencyContactPhone != null ? ' (${student.emergencyContactPhone})' : ''}'),
                        if ((student.address ?? '').isNotEmpty)
                          _infoRow(
                              Icons.home_outlined, 'Address', student.address!),
                        if ((student.notes ?? '').isNotEmpty)
                          _infoRow(Icons.notes_rounded, 'Notes', student.notes!),
                      ],
                    ),
                  ),
                ),
                const SectionHeader(title: 'This Month Attendance'),
                FutureBuilder<List<MonthlyAttendanceSummary>>(
                  future: _attendanceFuture,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return ErrorView(message: snapshot.error.toString());
                    }
                    final rows = snapshot.data ?? [];
                    final mine = rows
                        .where((r) => r.studentId == widget.studentId)
                        .toList();
                    if (rows.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No attendance marked for this month yet.',
                          style:
                              TextStyle(color: TandavColors.textSecondary),
                        ),
                      );
                    }
                    final attendance = mine.isNotEmpty ? mine.first : null;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: attendance == null
                            ? const Text(
                                'No attendance marked for this month.',
                                style: TextStyle(
                                    color: TandavColors.textSecondary),
                              )
                            : Column(
                                children: [
                                  _attendanceBar(attendance),
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceAround,
                                    children: [
                                      _attCount('Classes',
                                          '${attendance.totalClasses}'),
                                      _attCount('Present',
                                          '${attendance.presents}',
                                          color: TandavColors.success),
                                      _attCount('Late',
                                          '${attendance.lates}',
                                          color: TandavColors.yellow),
                                      _attCount('Absent',
                                          '${attendance.absents}',
                                          color: TandavColors.danger),
                                    ],
                                  ),
                                ],
                              ),
                      ),
                    );
                  },
                ),
                const SectionHeader(title: 'Monthly Fees'),
                FutureBuilder<FeeListResponse>(
                  future: _feesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child:
                            Center(child: CircularProgressIndicator()),
                      );
                    }
                    final fees = snapshot.data?.items ?? [];
                    if (fees.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: EmptyView(
                          icon: Icons.payments_outlined,
                          title: 'No fee records yet',
                          subtitle:
                              'Create a fee record for a month to start tracking.',
                          action: OutlinedButton.icon(
                            onPressed: () => _createFee(),
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('New Fee Record'),
                          ),
                        ),
                      );
                    }
                    return Column(
                      children: fees
                          .map((f) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _feeTile(f),
                              ))
                          .toList(),
                    );
                  },
                ),
                const SectionHeader(title: 'Monthly Progress'),
                FutureBuilder<ProgressListResponse>(
                  future: _progressFuture,
                  builder: (context, snapshot) {
                    final items = snapshot.data?.items ?? [];
                    if (items.isEmpty && snapshot.connectionState == ConnectionState.done) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: EmptyView(
                          icon: Icons.trending_up_rounded,
                          title: 'No progress recorded',
                          subtitle:
                              'Capture skill, performance and discipline ratings per month.',
                          action: OutlinedButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    ProgressScreen(studentId: widget.studentId),
                              ),
                            ),
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Record Progress'),
                          ),
                        ),
                      );
                    }
                    return Column(
                      children: items
                          .take(4)
                          .map((p) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _progressTile(p),
                              ))
                          .toList(),
                    );
                  },
                ),
                const SectionHeader(title: 'Payment History'),
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: _paymentsFuture,
                  builder: (context, snapshot) {
                    final payments = snapshot.data ?? [];
                    if (payments.isEmpty && snapshot.connectionState == ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No payments recorded yet.',
                          style: TextStyle(color: TandavColors.textSecondary),
                        ),
                      );
                    }
                    return Column(
                      children: payments
                          .map((p) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _paymentTile(p),
                              ))
                          .toList(),
                    );
                  },
                ),
                const SectionHeader(title: 'Actions'),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pickAndUploadPhoto,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Photo'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              ProgressScreen(studentId: widget.studentId),
                        ),
                      ),
                      icon: const Icon(Icons.trending_up_rounded),
                      label: const Text('Progress'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                StudentFormScreen(student: student),
                          ),
                        );
                        _reloadAll();
                      },
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _header(Student student) {
    final photoUrl = student.photoUrl;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            GestureDetector(
              onTap: _pickAndUploadPhoto,
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 34,
                    backgroundColor: TandavColors.surfaceLight,
                    foregroundImage: photoUrl != null &&
                            File(photoUrl).existsSync()
                        ? FileImage(File(photoUrl))
                        : null,
                    child: Text(
                      student.firstName.isNotEmpty
                          ? student.firstName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: TandavColors.gold,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: const BoxDecoration(
                        color: TandavColors.gold,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.add_a_photo_rounded,
                          size: 13, color: Color(0xFF141414)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          student.fullName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w900,
                            color: TandavColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    student.gender.isEmpty
                        ? '—'
                        : student.gender,
                    style: const TextStyle(
                        color: TandavColors.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
            StatusBadge(
                status: student.isActive ? 'active' : 'inactive',
                label: student.isActive ? 'Active' : 'Inactive'),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: TandavColors.gold),
          const SizedBox(width: 10),
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: const TextStyle(
                color: TandavColors.textMuted,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: TandavColors.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _attendanceBar(MonthlyAttendanceSummary a) {
    final pct = a.percentage;
    final color = pct >= 85
        ? TandavColors.success
        : pct >= 60
            ? TandavColors.yellow
            : TandavColors.danger;
    return Column(
      children: [
        Row(
          children: [
            const Text(
              'Attendance',
              style: TextStyle(
                  fontSize: 13, color: TandavColors.textSecondary),
            ),
            const Spacer(),
            Text(
              '${pct.toStringAsFixed(1)}%',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: LinearProgressIndicator(
            value: (pct / 100).clamp(0, 1),
            minHeight: 8,
            backgroundColor: TandavColors.surfaceBorder,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }

  Widget _attCount(String label, String value, {Color color = TandavColors.textPrimary}) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w900,
            color: color,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
              fontSize: 11, color: TandavColors.textMuted),
        ),
      ],
    );
  }

  Widget _feeTile(Fee f) {
    final paid = f.status == 'paid';
    return Card(
      child: ListTile(
        onTap: () => _payFee(f),
        leading: const Icon(Icons.currency_rupee_rounded,
            color: TandavColors.gold),
        title: Text(
          Fmt.monthLabel(f.month),
          style: const TextStyle(
              fontWeight: FontWeight.w700, color: TandavColors.textPrimary),
        ),
        subtitle: Text(
          '${Fmt.money(f.paidValue)} paid of ${Fmt.money(f.dueValue)}',
          style: const TextStyle(
              fontSize: 12.5, color: TandavColors.textSecondary),
        ),
        trailing: paid
            ? StatusBadge(status: f.status)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusBadge(status: f.status),
                  const SizedBox(width: 8),
                  if (_busyFeeId == f.id)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: () => _markPaid(f),
                      icon: const Icon(Icons.check_rounded, size: 16),
                      label: const Text('Mark Paid'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: TandavColors.gold,
                        side: const BorderSide(color: TandavColors.gold),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _paymentTile(Map<String, dynamic> p) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.payments_outlined,
            color: TandavColors.success, size: 20),
        title: Text(
          '${Fmt.money(double.tryParse(p['amount']?.toString() ?? '') ?? 0)} '
          '· ${Fmt.monthLabel(p['month'] as String? ?? '')}',
          style: const TextStyle(
              fontWeight: FontWeight.w700, color: TandavColors.textPrimary),
        ),
        subtitle: Text(
          'Paid on ${Fmt.date(p['payment_date'] as String?)}'
          '${p['payment_method'] != null ? ' · ${(p['payment_method'] as String).toUpperCase()}' : ''}',
          style: const TextStyle(
              fontSize: 12.5, color: TandavColors.textSecondary),
        ),
      ),
    );
  }

  Widget _progressTile(MonthlyProgress p) {
    final score = p.overallScore;
    final color = score >= 80
        ? TandavColors.success
        : score >= 60
            ? TandavColors.yellow
            : TandavColors.danger;
    return Card(
      child: ListTile(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ProgressScreen(studentId: widget.studentId),
          ),
        ),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Text(
            '${score.toStringAsFixed(0)}',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
        ),
        title: Text(
          Fmt.monthLabel(p.month),
          style: const TextStyle(
              fontWeight: FontWeight.w700, color: TandavColors.textPrimary),
        ),
        subtitle: Text(
          'Skill ${p.skillRating} · Perf ${p.performanceRating} · Disc ${p.disciplineRating}',
          style: const TextStyle(
              fontSize: 12.5, color: TandavColors.textSecondary),
        ),
      ),
    );
  }

  Future<void> _createFee() async {
    final api = context.read<TandavApi>();
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: TandavColors.surface,
      isScrollControlled: true,
      builder: (_) => const _NewFeeSheet(),
    );
    if (result == null || !mounted) return;
    try {
      await api.createFee(
          widget.studentId, result['month'] as String, result['amount'] as String);
      Alert.show(context, 'Fee record created');
      _reloadAll();
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    }
  }

  Future<void> _payFee(Fee f) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: TandavColors.surface,
      isScrollControlled: true,
      builder: (_) => FeePaymentSheet(fee: f),
    );
    _reloadAll();
  }

  Future<void> _markPaid(Fee f) async {
    final remaining = f.outstanding;
    if (remaining <= 0) return;
    setState(() => _busyFeeId = f.id);
    try {
      final api = context.read<TandavApi>();
      final now = DateTime.now();
      final iso = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      await api.recordFeePayment(f.id, remaining, iso, 'cash');
      if (!mounted) return;
      Alert.show(context,
          '${Fmt.monthLabel(f.month)} fee marked as paid');
      _reloadAll();
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busyFeeId = null);
    }
  }
}

class _NewFeeSheet extends StatefulWidget {
  const _NewFeeSheet();

  @override
  State<_NewFeeSheet> createState() => _NewFeeSheetState();
}

class _NewFeeSheetState extends State<_NewFeeSheet> {
  late DateTime _month = DateTime.now();
  final _amount = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  String get _iso =>
      '${_month.year.toString().padLeft(4, '0')}-${_month.month.toString().padLeft(2, '0')}-01';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'New Fee Record',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  color: TandavColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _month,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                    helpText: 'Select month',
                  );
                  if (picked != null) setState(() => _month = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Month',
                    prefixIcon: Icon(Icons.calendar_month_outlined),
                  ),
                  child: Text(Fmt.monthLabel(_iso)),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Amount due (\u20B9)',
                  prefixIcon: Icon(Icons.currency_rupee_rounded),
                ),
                validator: (v) {
                  final amt = double.tryParse(v ?? '');
                  if (amt == null || amt <= 0) return 'Enter a valid amount';
                  return null;
                },
              ),
              const SizedBox(height: 18),
              GoldButton(
                label: 'Create Record',
                icon: Icons.add_rounded,
                expanded: true,
                onPressed: () {
                  if (!_formKey.currentState!.validate()) return;
                  Navigator.pop(context, {
                    'month': _iso,
                    'amount': _amount.text.trim(),
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}