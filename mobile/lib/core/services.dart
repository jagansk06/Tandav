import '../database/tandav_database.dart';
import '../models/attendance.dart';
import '../models/batch.dart';
import '../models/dashboard.dart';
import '../models/event.dart';
import '../models/fee.dart';
import '../models/progress.dart';
import '../models/student.dart';
import '../platform/app_files.dart' show BackupEntry;
import '../repositories/attendance_repository.dart';
import '../repositories/auth_repository.dart';
import '../repositories/batch_repository.dart';
import '../repositories/dashboard_repository.dart';
import '../repositories/event_repository.dart';
import '../repositories/export_repository.dart';
import '../repositories/fee_repository.dart';
import '../repositories/progress_repository.dart';
import '../repositories/student_repository.dart';
import '../sync/cloud_sync.dart';
import '../sync/drive_mailbox.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_mailbox.dart';
import '../sync/sync_state.dart';
import 'app_role.dart';

/// Tandav local data service.
///
/// This is the single entry point used by every screen. The method set below
/// is intentionally identical to the previous remote API facade so screens
/// never had to change — but every operation now runs against the local
/// SQLite database instead of FastAPI/PostgreSQL. The application is fully
/// offline: no network, no server, no laptop required.
class TandavApi {
  final TandavDatabase db;
  TandavApi({TandavDatabase? database, SyncMailbox? mailbox})
      : db = database ?? TandavDatabase.instance,
        _mailbox = mailbox;

  final SyncMailbox? _mailbox;

  late final AuthRepository auth = AuthRepository(db);
  late final BatchRepository batches = BatchRepository(db);
  late final StudentRepository students = StudentRepository(db);
  late final AttendanceRepository attendance = AttendanceRepository(db);
  late final FeeRepository fees = FeeRepository(db);
  late final EventRepository events = EventRepository(db);
  late final ProgressRepository progress = ProgressRepository(db);
  late final DashboardRepository dashboard = DashboardRepository(db, fees);
  late final ExportRepository export = ExportRepository(db);

  // ---- Sync ----
  late final SyncState syncState = SyncState(db);

  /// The merge engine, scoped to the tables **this build** is allowed to hold.
  ///
  /// [syncTables] is passed explicitly even though the engine defaults to it,
  /// because this is the one line in the app where the attender build's data
  /// boundary is actually established. An implicit default here would make the
  /// most security-relevant decision in the codebase invisible at its call site.
  late final SyncEngine syncEngine =
      SyncEngine(db, syncState, tables: syncTables);

  /// Where the studio's devices leave files for each other. Built lazily so
  /// tests can inject a fake and never construct a Google client.
  late final SyncMailbox mailbox = _mailbox ?? DriveMailbox();

  /// The one and only sync path: a shared Google Drive account acting as a
  /// store-and-forward mailbox. A Bluetooth transport used to sit alongside
  /// this; it was removed because the masters are in different places, so it
  /// could never carry the everyday case.
  late final CloudSyncManager cloudSync = CloudSyncManager(
    db: db,
    state: syncState,
    engine: syncEngine,
    mailbox: mailbox,
  );

  /// Generate missing monthly fee records for the current month (and any
  /// months missed while the app was closed). Idempotent; call at startup
  /// and on app resume.
  Future<int> ensureMonthlyFees() => fees.ensureMonthlyFees(DateTime.now());

  // ---- Batches ----
  Future<BatchListResponse> getBatches({String? search, bool activeOnly = false}) =>
      batches.getBatches(search: search, activeOnly: activeOnly);

  Future<Batch> getBatch(int id) => batches.getBatch(id);

  Future<Batch> createBatch(Map<String, dynamic> payload) => batches.createBatch(payload);

  Future<Batch> updateBatch(int id, Map<String, dynamic> payload) => batches.updateBatch(id, payload);

  Future<void> deleteBatch(int id) => batches.deleteBatch(id);

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
    return s;
  }

  Future<Student> updateStudent(int id, Map<String, dynamic> payload) => students.updateStudent(id, payload);

  Future<void> deleteStudent(int id) => students.deleteStudent(id);

  /// Save a picked photo into app documents and return its local path.
  ///
  /// `sourcePath` rather than a `File` so this signature survives the web
  /// build, where `dart:io` does not exist. Android only — guard on
  /// `appFiles.supportsPhotos`.
  Future<String> uploadPhoto(int studentId, String sourcePath, String filename) =>
      students.savePhoto(studentId, sourcePath, filename);

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

  Future<List<Map<String, dynamic>>> getStudentDailyAttendance(
    int studentId,
    String month,
  ) =>
      attendance.getStudentDailyAttendance(studentId, month);

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

  /// The configurable fixed rupee amount added to a month's fee when the
  /// student did not pay the previous month. See [FeeRepository].
  Future<double> getLateFeePenalty() => fees.getLateFeePenalty();

  Future<void> setLateFeePenalty(double amount) =>
      fees.setLateFeePenalty(amount);

  // ---- UPI payments ----
  Future<String?> getUpiVpa() => fees.getUpiVpa();
  Future<void> setUpiVpa(String vpa) => fees.setUpiVpa(vpa);
  Future<String?> getUpiPayee() => fees.getUpiPayee();
  Future<void> setUpiPayee(String payee) => fees.setUpiPayee(payee);

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

  // ---- CSV export ----
  /// CSV of every active/archived student with contact and batch details.
  Future<String> exportStudentsCsv() => export.exportStudents();

  /// CSV of every batch with its default fee and student headcount.
  Future<String> exportBatchesCsv() => export.exportBatches();

  /// CSV of the monthly fee register (optionally one month).
  Future<String> exportMonthlyFeesCsv({String? month}) =>
      export.exportMonthlyFees(month: month);

  /// CSV of the monthly attendance summary (optionally one month / batch).
  Future<String> exportAttendanceCsv({String? month, int? batchId}) =>
      export.exportAttendance(month: month, batchId: batchId);

  // ---- Backup / restore ----
  // Android only. `appFiles.supportsBackups` is false in the iPhone PWA and
  // these throw there; the menu hides them rather than calling.
  Future<BackupEntry> createBackup() => db.createBackup();

  Future<List<BackupEntry>> listBackups() => db.listBackups();

  Future<bool> restoreFromBackup(BackupEntry backup) =>
      db.restoreFromBackup(backup);
}