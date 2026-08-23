import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../database/tandav_database.dart';
import '../models/attendance.dart';
import '../models/batch.dart';
import '../models/dashboard.dart';
import '../models/event.dart';
import '../models/fee.dart';
import '../models/progress.dart';
import '../models/student.dart';
import '../platform/tandav_platform.dart';
import '../repositories/attendance_repository.dart';
import '../repositories/auth_repository.dart';
import '../repositories/batch_repository.dart';
import '../repositories/dashboard_repository.dart';
import '../repositories/event_repository.dart';
import '../repositories/fee_repository.dart';
import '../repositories/progress_repository.dart';
import '../repositories/student_repository.dart';
import '../sync/drive/drive_sync_manager.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_state.dart';

/// Tandav local data service.
///
/// This is the single entry point used by every screen. The method set below
/// is intentionally identical to the previous remote API facade so screens
/// never had to change — but every operation now runs against the local
/// SQLite database instead of FastAPI/PostgreSQL. The application is fully
/// offline: no network, no server, no laptop required.
class TandavApi {
  final TandavDatabase db;
  TandavApi({TandavDatabase? database}) : db = database ?? TandavDatabase.instance;

  late final AuthRepository auth = AuthRepository(db);
  late final BatchRepository batches = BatchRepository(db);
  late final StudentRepository students = StudentRepository(db);
  late final AttendanceRepository attendance = AttendanceRepository(db);
  late final FeeRepository fees = FeeRepository(db);
  late final EventRepository events = EventRepository(db);
  late final ProgressRepository progress = ProgressRepository(db);
  late final DashboardRepository dashboard = DashboardRepository(db, fees);

  // ---- Sync ----
  late final SyncState syncState = SyncState(db);
  late final SyncEngine syncEngine = SyncEngine(db, syncState);

  /// Google Drive synchronization. Works identically on Android and in the
  /// browser; the platform-specific part is only how the Google access token is
  /// obtained. Nothing here is required for normal use — Tandav is fully
  /// functional offline and only touches the network when the user syncs.
  late final DriveSyncManager sync = DriveSyncManager(
    db: db,
    state: syncState,
    engine: syncEngine,
  )..onDataChanged = bumpRevision;

  /// Incremented whenever business data changes in a way that other screens
  /// may already be displaying — a local create/update/delete, a Drive sync
  /// that applied remote rows, or a database restore.
  ///
  /// Screens that cache query results (for example the Attendance batch
  /// dropdown) listen to this and reload, so a batch created on the Batches
  /// tab or arriving from the other device shows up without restarting the
  /// app. Deliberately *not* bumped by high-frequency writes such as marking
  /// attendance, which would fight with the screen doing the writing.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Announce that shared business data changed. Safe to call from anywhere.
  void bumpRevision() => revision.value++;

  /// Run a mutation, then announce the change once it has committed.
  Future<T> _mutating<T>(Future<T> op) async {
    final result = await op;
    bumpRevision();
    return result;
  }

  /// Generate missing monthly fee records for the current month (and any
  /// months missed while the app was closed). Idempotent; call at startup
  /// and on app resume.
  Future<int> ensureMonthlyFees() => fees.ensureMonthlyFees(DateTime.now());

  // ---- Batches ----
  Future<BatchListResponse> getBatches({String? search, bool activeOnly = false}) =>
      batches.getBatches(search: search, activeOnly: activeOnly);

  Future<Batch> getBatch(int id) => batches.getBatch(id);

  Future<Batch> createBatch(Map<String, dynamic> payload) =>
      _mutating(batches.createBatch(payload));

  Future<Batch> updateBatch(int id, Map<String, dynamic> payload) =>
      _mutating(batches.updateBatch(id, payload));

  Future<void> deleteBatch(int id) => _mutating(batches.deleteBatch(id));

  // ---- Students ----
  Future<StudentListResponse> getStudents({
    String? q,
    int? batchId,
    bool activeOnly = false,
    String? gender,
  }) =>
      students.getStudents(
          q: q, batchId: batchId, activeOnly: activeOnly, gender: gender);

  Future<Student> getStudent(int id) => students.getStudent(id);

  Future<Student> createStudent(Map<String, dynamic> payload) async {
    final s = await students.createStudent(payload);
    // New students automatically receive a fee record for their join month
    // and every month since (existing records are never duplicated).
    final join = DateTime.tryParse(payload['join_date'] ?? '');
    await fees.ensureMonthlyFees(DateTime.now(), anchor: join ?? DateTime.now());
    bumpRevision();
    return s;
  }

  Future<Student> updateStudent(int id, Map<String, dynamic> payload) =>
      _mutating(students.updateStudent(id, payload));

  Future<void> deleteStudent(int id) => _mutating(students.deleteStudent(id));

  /// Store a picked photo for a student and return its local handle.
  Future<String> uploadPhoto(int studentId, Uint8List bytes, String filename) =>
      students.savePhoto(studentId, bytes, filename);

  // ---- Attendance ----
  Future<AttendanceDay> getAttendanceDay(String date, {int? batchId}) =>
      attendance.getAttendanceDay(date, batchId: batchId);

  Future<AttendanceDay> saveAttendanceDay({
    required String date,
    required int batchId,
    required List<Map<String, dynamic>> records,
  }) =>
      attendance.saveAttendanceDay(
          date: date, batchId: batchId, records: records);

  Future<List<MonthlyAttendanceSummary>> getMonthlyAttendance(
    String month, {
    int? batchId,
  }) =>
      attendance.getMonthlyAttendance(month, batchId: batchId);

  // ---- Fees ----
  Future<FeeListResponse> getFees({String? month, int? studentId, int? batchId, String? status, String? q}) =>
      fees.getFees(month: month, studentId: studentId, batchId: batchId, status: status, q: q);

  Future<FeeSummary> getFeeSummary(String month, {int? batchId}) =>
      fees.getFeeSummary(month, batchId: batchId);

  Future<Fee> createFee(int studentId, String month, String amountDue) =>
      fees.createFee(studentId, month, amountDue);

  Future<Fee> recordFeePayment(int feeId, double amount, String paymentDate, String method) =>
      fees.recordFeePayment(feeId, amount, paymentDate, method);

  /// One-tap full payment for a month (uses the phone's current date).
  Future<Fee> markFeePaid(int feeId) => fees.markFeePaid(feeId);

  /// One-tap reversal back to DUE (removes amount from collected totals).
  Future<Fee> markFeeDue(int feeId) => fees.markFeeDue(feeId);

  Future<Fee> updateFee(int feeId, {String? amountDue}) =>
      fees.updateFee(feeId, amountDue: amountDue);

  Future<void> deleteFee(int feeId) => fees.deleteFee(feeId);

  /// Payment-history ledger for a student (used on the profile screen).
  Future<List<Map<String, dynamic>>> paymentHistory(int studentId) =>
      fees.paymentHistory(studentId);

  // ---- Events ----
  Future<EventListResponse> getEvents({String? q, bool? upcomingOnly, bool? pastOnly}) =>
      events.getEvents(q: q, upcomingOnly: upcomingOnly, pastOnly: pastOnly);

  Future<EventItem> getEvent(int id) => events.getEvent(id);

  Future<EventItem> createEvent(Map<String, dynamic> payload) => events.createEvent(payload);

  Future<EventItem> updateEvent(int id, Map<String, dynamic> payload) => events.updateEvent(id, payload);

  Future<void> deleteEvent(int id) => events.deleteEvent(id);

  Future<ParticipationListResponse> getParticipants(int eventId, {String? costumeStatus}) =>
      events.getParticipants(eventId, costumeStatus: costumeStatus);

  Future<CostumeSummary> getCostumeSummary(int eventId) => events.getCostumeSummary(eventId);

  Future<ParticipationListResponse> addBatchParticipants(
          int eventId, int batchId, {String costumeFee = '0'}) =>
      events.addBatchParticipants(eventId, batchId, costumeFee: costumeFee);

  Future<ParticipationListResponse> addParticipants(
    int eventId,
    List<int> studentIds, {
    String? source,
    bool isCostumeRequired = false,
    String costumeFee = '0',
  }) =>
      events.addParticipants(eventId, studentIds,
          source: source,
          isCostumeRequired: isCostumeRequired,
          costumeFee: costumeFee);

  Future<EventParticipation> updateParticipation(int id, Map<String, dynamic> payload) =>
      events.updateParticipation(id, payload);

  Future<void> removeParticipant(int id) => events.removeParticipant(id);

  Future<ParticipationListResponse> studentParticipationHistory(int studentId) =>
      events.studentParticipationHistory(studentId);

  // ---- Progress ----
  Future<MonthlyProgress> createProgress(int studentId, Map<String, dynamic> payload) =>
      progress.createProgress(studentId, payload);

  Future<MonthlyProgress> updateProgress(
          int studentId, String month, Map<String, dynamic> payload) =>
      progress.updateProgress(studentId, month, payload);

  Future<ProgressListResponse> getProgress({String? month, int? studentId, int? batchId}) =>
      progress.getProgress(month: month, studentId: studentId, batchId: batchId);

  Future<ProgressListResponse> studentProgressHistory(int studentId) =>
      progress.getProgress(studentId: studentId);

  // ---- Dashboard ----
  Future<DashboardData> getDashboard({String? month}) =>
      dashboard.getDashboard(month: month);

  // ---- Reports ----
  Future<MonthlyReport> getMonthlyReport(String month) =>
      dashboard.getMonthlyReport(month);

  // ---- Backup / restore ----

  /// False in the browser, where there is no database file to copy — the
  /// Backup and Restore actions are hidden there instead of failing.
  bool get supportsLocalBackup => db.supportsLocalBackup;

  Future<BackupRef> createBackup() => db.createBackup();

  Future<List<BackupRef>> listBackups() => db.listBackups();

  Future<bool> restoreFromBackup(BackupRef backup) =>
      _mutating(db.restoreFromBackup(backup));
}