import 'package:sqflite/sqflite.dart';

import '../database/db_helpers.dart';
import '../database/tandav_database.dart';
import '../models/event.dart';
import '../sync/sync_meta.dart';

class EventRepository {
  final TandavDatabase db;
  EventRepository(this.db);

  Future<Database> get _d => db.open();

  static String costumeStatus({required bool required, required double due, required double paid}) {
    if (!required || due <= 0) return 'none';
    if (paid >= due - 0.001) return 'paid';
    if (paid > 0) return 'partial';
    return 'due';
  }

  Future<EventListResponse> getEvents({String? q, bool? upcomingOnly, bool? pastOnly}) async {
    final d = await _d;
    final where = <String>[];
    final args = <Object?>[];
    if (q != null && q.trim().isNotEmpty) {
      where.add('e.name LIKE ?');
      args.add('%${q.trim()}%');
    }
    final today = DbFmt.date(DateTime.now());
    if (upcomingOnly == true) {
      where.add('e.event_date >= ?');
      args.add(today);
    }
    if (pastOnly == true) {
      where.add('e.event_date < ?');
      args.add(today);
    }
    final rows = await d.rawQuery('''
      SELECT e.*, b.name AS batch_name,
             (SELECT COUNT(*) FROM event_participations ep
              WHERE ep.event_id = e.id AND ep.deleted_at IS NULL) AS participant_count
      FROM events e
      LEFT JOIN batches b ON b.id = e.batch_id
      ${where.isEmpty ? 'WHERE e.deleted_at IS NULL' : 'WHERE ${where.join(' AND ')} AND e.deleted_at IS NULL'}
      ORDER BY e.event_date DESC, e.id DESC
      LIMIT 200
    ''', args);
    return EventListResponse(
      items: rows.map(_eventFromRow).toList(),
      total: rows.length,
    );
  }

  Future<EventItem> getEvent(int id) async {
    final d = await _d;
    final rows = await d.rawQuery('''
      SELECT e.*, b.name AS batch_name,
             (SELECT COUNT(*) FROM event_participations ep
              WHERE ep.event_id = e.id AND ep.deleted_at IS NULL) AS participant_count
      FROM events e
      LEFT JOIN batches b ON b.id = e.batch_id
      WHERE e.id = ? AND e.deleted_at IS NULL
    ''', [id]);
    if (rows.isEmpty) throw RepoException('Event not found');
    return _eventFromRow(rows.first);
  }

  Future<EventItem> createEvent(Map<String, dynamic> payload) async {
    final d = await _d;
    final id = await d.insert('events',
        {..._payloadToRow(payload), ...SyncStamp.now(db).columns()});
    return getEvent(id);
  }

  Future<EventItem> updateEvent(int id, Map<String, dynamic> payload) async {
    final d = await _d;
    final row = _payloadToRow(payload);
    row.addAll(SyncStamp.now(db).touchColumns());
    final updated = await d.update('events', row, where: 'id = ?', whereArgs: [id]);
    if (updated == 0) throw RepoException('Event not found');
    return getEvent(id);
  }

  Future<void> deleteEvent(int id) async {
    final d = await _d;
    final updated = await d.update('events', {
      ...SyncStamp.now(db).tombstoneColumns(),
    }, where: 'id = ?', whereArgs: [id]);
    if (updated == 0) throw RepoException('Event not found');
  }

  Future<ParticipationListResponse> getParticipants(int eventId, {String? costumeStatus}) async {
    final d = await _d;
    final conditions = <String>['ep.event_id = ?', 'ep.deleted_at IS NULL'];
    final args = <Object?>[eventId];
    if (costumeStatus != null && costumeStatus.isNotEmpty) {
      conditions.add('ep.costume_status = ?');
      args.add(costumeStatus);
    }
    final rows = await d.rawQuery('''
      SELECT ep.*, s.first_name, s.last_name, b.name AS batch_name
      FROM event_participations ep
      JOIN students s ON s.id = ep.student_id
      LEFT JOIN batches b ON b.id = s.batch_id
      WHERE ${conditions.join(' AND ')}
      ORDER BY s.first_name COLLATE NOCASE
    ''', args);
    return ParticipationListResponse(
      items: rows.map(_participationFromRow).toList(),
      total: rows.length,
    );
  }

  Future<CostumeSummary> getCostumeSummary(int eventId) async {
    final d = await _d;
    final rows = await d.query('event_participations',
        where: 'event_id = ? AND deleted_at IS NULL', whereArgs: [eventId]);
    double due = 0, paid = 0;
    for (final r in rows) {
      due += _fee(r['costume_fee_due']);
      paid += _fee(r['costume_fee_paid']);
    }
    return CostumeSummary(
      totalDue: due.toStringAsFixed(2),
      totalPaid: paid.toStringAsFixed(2),
      outstanding: (due - paid).toStringAsFixed(2),
    );
  }

  /// Add every student of a batch to the event (duplicates skipped).
  Future<ParticipationListResponse> addBatchParticipants(
    int eventId,
    int batchId, {
    String costumeFee = '0',
  }) async {
    final d = await _d;
    final students = await d.query('students',
        where: 'batch_id = ? AND is_active = 1 AND deleted_at IS NULL',
        whereArgs: [batchId]);
    await _insertParticipants(d, eventId,
        students.map((s) => s['id'] as int).toList(),
        costumeFee: costumeFee);
    return getParticipants(eventId);
  }

  Future<ParticipationListResponse> addParticipants(
    int eventId,
    List<int> studentIds, {
    String? source,
    bool isCostumeRequired = false,
    String costumeFee = '0',
  }) async {
    final d = await _d;
    await _insertParticipants(d, eventId, studentIds,
        costumeFee: costumeFee,
        isCostumeRequired: isCostumeRequired,
        source: source ?? 'individual');
    return getParticipants(eventId);
  }

  Future<void> _insertParticipants(
    Database d,
    int eventId,
    List<int> studentIds, {
    required String costumeFee,
    bool isCostumeRequired = false,
    String source = 'individual',
  }) async {
    if (studentIds.isEmpty) return;
    final event = await d.query('events',
        where: 'id = ?', whereArgs: [eventId], limit: 1);
    if (event.isEmpty) throw RepoException('Event not found');
    final due = double.tryParse(costumeFee) ?? 0;
    await d.transaction((t) async {
      for (final sid in studentIds) {
        final student = await t.query('students',
            where: 'id = ? AND deleted_at IS NULL', whereArgs: [sid], limit: 1);
        if (student.isEmpty) continue;
        final existing = await t.query('event_participations',
            where: 'event_id = ? AND student_id = ?',
            whereArgs: [eventId, sid], limit: 1);
        final stamp = SyncStamp.now(db);
        if (existing.isNotEmpty) {
          await t.update('event_participations', {
            'source': source,
            'is_costume_required': isCostumeRequired ? 1 : 0,
            'costume_fee_due': DbFmt.round2(due),
            'costume_fee_paid': 0,
            'costume_status':
                costumeStatus(required: isCostumeRequired, due: due, paid: 0),
            'deleted_at': null,
            ...stamp.touchColumns(),
          }, where: 'event_id = ? AND student_id = ?',
              whereArgs: [eventId, sid]);
        } else {
          await t.insert('event_participations', {
            'event_id': eventId,
            'student_id': sid,
            'source': source,
            'is_costume_required': isCostumeRequired ? 1 : 0,
            'costume_fee_due': DbFmt.round2(due),
            'costume_fee_paid': 0,
            'costume_status':
                costumeStatus(required: isCostumeRequired, due: due, paid: 0),
            ...stamp.columns(),
          });
        }
      }
    });
  }

  Future<EventParticipation> updateParticipation(
      int id, Map<String, dynamic> payload) async {
    final d = await _d;
    final existing = await d.query('event_participations',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (existing.isEmpty) throw RepoException('Participation not found');
    final row = existing.first;

    final required = (payload['is_costume_required'] as bool?) ?? (row['is_costume_required'] as int? ?? 0) == 1;
    final due = _payloadFee(payload['costume_fee_due']) ?? _fee(row['costume_fee_due']);
    final paid = _payloadFee(payload['costume_fee_paid']) ?? _fee(row['costume_fee_paid']);
    if (paid > due + 0.001) {
      throw RepoException('Payment exceeds total fee');
    }
    final status = costumeStatus(required: required, due: due, paid: paid);

    final update = <String, Object?>{
      'is_costume_required': required ? 1 : 0,
      'costume_fee_due': DbFmt.round2(due),
      'costume_fee_paid': DbFmt.round2(paid),
      'costume_status': status,
      'costume_paid_date':
          payload['costume_paid_date'] ?? (paid > 0 ? row['costume_paid_date'] : null),
      'costume_payment_method':
          payload['costume_payment_method'] ?? row['costume_payment_method'],
      'notes': payload['notes'] ?? row['notes'],
    };
    await d.update('event_participations', update, where: 'id = ?', whereArgs: [id]);
    await d.update('event_participations', {
      ...SyncStamp.now(db).touchColumns(),
    }, where: 'id = ?', whereArgs: [id]);

    final rows = await d.rawQuery('''
      SELECT ep.*, s.first_name, s.last_name, b.name AS batch_name
      FROM event_participations ep
      JOIN students s ON s.id = ep.student_id
      LEFT JOIN batches b ON b.id = s.batch_id
      WHERE ep.id = ?
    ''', [id]);
    return _participationFromRow(rows.first);
  }

  Future<void> removeParticipant(int id) async {
    final d = await _d;
    final updated = await d.update('event_participations', {
      ...SyncStamp.now(db).tombstoneColumns(),
    }, where: 'id = ?', whereArgs: [id]);
    if (updated == 0) throw RepoException('Participation not found');
  }

  Future<ParticipationListResponse> studentParticipationHistory(int studentId) async {
    final d = await _d;
    final rows = await d.rawQuery('''
      SELECT ep.*, s.first_name, s.last_name, b.name AS batch_name,
             e.name AS event_name, e.event_date
      FROM event_participations ep
      JOIN students s ON s.id = ep.student_id
      JOIN events e ON e.id = ep.event_id
      LEFT JOIN batches b ON b.id = s.batch_id
      WHERE ep.student_id = ? AND ep.deleted_at IS NULL
        AND e.deleted_at IS NULL AND s.deleted_at IS NULL
      ORDER BY e.event_date DESC
    ''', [studentId]);
    return ParticipationListResponse(
      items: rows.map(_participationFromRow).toList(),
      total: rows.length,
    );
  }

  Map<String, Object?> _payloadToRow(Map<String, dynamic> payload) => {
        'name': (payload['name'] as String).trim(),
        'description': payload['description'],
        'event_type': (payload['event_type'] as String?) ?? '',
        'event_date': payload['event_date'],
        'location': payload['location'],
        'batch_id': payload['batch_id'],
        'is_active': payload['is_active'] == false ? 0 : 1,
      };

  double? _payloadFee(Object? v) {
    if (v == null) return null;
    final n = double.tryParse(v.toString());
    return n == null ? null : DbFmt.round2(n);
  }

  double _fee(Object? v) {
    final n = double.tryParse(v?.toString() ?? '');
    return n == null ? 0 : DbFmt.round2(n);
  }

  EventItem _eventFromRow(Map<String, Object?> row) => EventItem(
        id: row['id'] as int,
        name: row['name'] as String,
        description: row['description'] as String?,
        eventType: (row['event_type'] as String?) ?? '',
        eventDate: row['event_date'] as String,
        location: row['location'] as String?,
        batchId: row['batch_id'] as int?,
        batchName: row['batch_name'] as String?,
        isActive: (row['is_active'] as int? ?? 1) == 1,
        participantCount: (row['participant_count'] as int?) ?? 0,
      );

  EventParticipation _participationFromRow(Map<String, Object?> row) =>
      EventParticipation(
        id: row['id'] as int,
        eventId: row['event_id'] as int,
        studentId: row['student_id'] as int,
        studentName: _names(row),
        batchName: row['batch_name'] as String?,
        source: (row['source'] as String?) ?? 'individual',
        isCostumeRequired: (row['is_costume_required'] as int? ?? 0) == 1,
        costumeFeeDue: (_fee(row['costume_fee_due'])).toStringAsFixed(2),
        costumeFeePaid: (_fee(row['costume_fee_paid'])).toStringAsFixed(2),
        costumeStatus: (row['costume_status'] as String?) ?? 'none',
        costumePaidDate: row['costume_paid_date'] as String?,
        costumePaymentMethod: row['costume_payment_method'] as String?,
        notes: row['notes'] as String?,
        registeredAt: (row['registered_at'] as String?) ?? '',
      );

  String _names(Map<String, Object?> row) {
    final first = (row['first_name'] as String?) ?? '';
    final last = (row['last_name'] as String?) ?? '';
    return '$first $last'.trim();
  }
}