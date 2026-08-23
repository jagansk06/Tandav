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
      LEFT JOIN batches b ON b.id = e.batch_id AND b.deleted_at IS NULL
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
      LEFT JOIN batches b ON b.id = e.batch_id AND b.deleted_at IS NULL
      WHERE e.id = ? AND e.deleted_at IS NULL
    ''', [id]);
    if (rows.isEmpty) throw const RepoException('Event not found');
    return _eventFromRow(rows.first);
  }

  Future<EventItem> createEvent(Map<String, dynamic> payload) async {
    final d = await _d;
    final id = await d.insert('events',
        {..._payloadToRow(payload), ...SyncStamp.now(db).columns()});
    return getEvent(id);
  }

  /// Apply an edit, writing only the fields present in [payload] so a caller
  /// that sends a subset cannot blank the rest of the event.
  Future<EventItem> updateEvent(int id, Map<String, dynamic> payload) async {
    final d = await _d;
    final row = _payloadToRow(payload, partial: true);
    row.addAll(SyncStamp.now(db).touchColumns());
    final updated = await d.update('events', row,
        where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
    if (updated == 0) throw const RepoException('Event not found');
    return getEvent(id);
  }

  /// Soft delete, together with the event's participations — the schema
  /// cascades on a real DELETE, but a tombstone triggers nothing, so the
  /// participations would otherwise stay live and sync on as rows belonging to
  /// an event that no longer exists.
  Future<void> deleteEvent(int id) async {
    final d = await _d;
    final updated = await d.transaction((txn) async {
      final stamp = SyncStamp.now(db);
      final rows = await txn.update('events', {
        'is_active': 0,
        ...stamp.tombstoneColumns(),
      }, where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
      if (rows != 0) {
        await txn.update('event_participations', stamp.tombstoneColumns(),
            where: 'event_id = ? AND deleted_at IS NULL', whereArgs: [id]);
      }
      return rows;
    });
    if (updated == 0) throw const RepoException('Event not found');
  }

  Future<ParticipationListResponse> getParticipants(int eventId, {String? costumeStatus}) async {
    final d = await _d;
    final conditions = <String>[
      'ep.event_id = ?',
      'ep.deleted_at IS NULL',
      's.deleted_at IS NULL',
    ];
    final args = <Object?>[eventId];
    if (costumeStatus != null && costumeStatus.isNotEmpty) {
      conditions.add('ep.costume_status = ?');
      args.add(costumeStatus);
    }
    final rows = await d.rawQuery('''
      SELECT ep.*, s.first_name, s.last_name, b.name AS batch_name
      FROM event_participations ep
      JOIN students s ON s.id = ep.student_id
      LEFT JOIN batches b ON b.id = s.batch_id AND b.deleted_at IS NULL
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
  ///
  /// A costume fee greater than zero implies a costume is required — the batch
  /// dialog has no separate switch, and without this the fee would be charged
  /// while the status stayed "none".
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
        costumeFee: costumeFee,
        isCostumeRequired: (double.tryParse(costumeFee) ?? 0) > 0,
        source: 'batch');
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

  /// Register students for an event, skipping anyone already registered.
  ///
  /// A participant who is already live is left completely untouched. Re-adding a
  /// batch is a routine action, and rewriting the row would reset
  /// `costume_fee_paid` to 0 — silently erasing a costume payment the admin had
  /// already recorded. Only a tombstoned participation is rewritten, which is
  /// how a removed student can be added back: `event_participations` is UNIQUE
  /// (event_id, student_id), so the deleted row must be revived rather than
  /// inserted again.
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
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [eventId],
        limit: 1);
    if (event.isEmpty) throw const RepoException('Event not found');
    final due = double.tryParse(costumeFee) ?? 0;
    await d.transaction((t) async {
      for (final sid in studentIds) {
        final student = await t.query('students',
            where: 'id = ? AND deleted_at IS NULL', whereArgs: [sid], limit: 1);
        if (student.isEmpty) continue;
        final existing = await t.query('event_participations',
            columns: ['id', 'deleted_at'],
            where: 'event_id = ? AND student_id = ?',
            whereArgs: [eventId, sid],
            limit: 1);
        final stamp = SyncStamp.now(db);
        final values = {
          'source': source,
          'is_costume_required': isCostumeRequired ? 1 : 0,
          'costume_fee_due': DbFmt.round2(due),
          'costume_fee_paid': 0,
          'costume_status':
              costumeStatus(required: isCostumeRequired, due: due, paid: 0),
        };
        if (existing.isEmpty) {
          await t.insert('event_participations', {
            'event_id': eventId,
            'student_id': sid,
            ...values,
            ...stamp.columns(),
          });
        } else if (existing.first['deleted_at'] != null) {
          await t.update('event_participations', {
            ...values,
            'costume_paid_date': null,
            'costume_payment_method': null,
            'deleted_at': null,
            ...stamp.touchColumns(),
          }, where: 'id = ?', whereArgs: [existing.first['id']]);
        }
      }
    });
  }

  Future<EventParticipation> updateParticipation(
      int id, Map<String, dynamic> payload) async {
    final d = await _d;
    final existing = await d.query('event_participations',
        where: 'id = ? AND deleted_at IS NULL', whereArgs: [id], limit: 1);
    if (existing.isEmpty) throw const RepoException('Participation not found');
    final row = existing.first;

    final required = (payload['is_costume_required'] as bool?) ?? (row['is_costume_required'] as int? ?? 0) == 1;
    final due = _payloadFee(payload['costume_fee_due']) ?? _fee(row['costume_fee_due']);
    final paid = _payloadFee(payload['costume_fee_paid']) ?? _fee(row['costume_fee_paid']);
    if (paid > due + 0.001) {
      throw const RepoException('Payment exceeds total fee');
    }
    final status = costumeStatus(required: required, due: due, paid: paid);

    // One statement: the business columns and the sync stamp have to move
    // together, or a sync landing between two writes would ship the old
    // `updated_at` with the new amounts and the peer would discard them.
    final updated = await d.update('event_participations', {
      'is_costume_required': required ? 1 : 0,
      'costume_fee_due': DbFmt.round2(due),
      'costume_fee_paid': DbFmt.round2(paid),
      'costume_status': status,
      'costume_paid_date':
          payload['costume_paid_date'] ?? (paid > 0 ? row['costume_paid_date'] : null),
      'costume_payment_method':
          payload['costume_payment_method'] ?? row['costume_payment_method'],
      'notes': payload['notes'] ?? row['notes'],
      ...SyncStamp.now(db).touchColumns(),
    }, where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
    if (updated == 0) throw const RepoException('Participation not found');

    final rows = await d.rawQuery('''
      SELECT ep.*, s.first_name, s.last_name, b.name AS batch_name
      FROM event_participations ep
      JOIN students s ON s.id = ep.student_id
      LEFT JOIN batches b ON b.id = s.batch_id AND b.deleted_at IS NULL
      WHERE ep.id = ?
    ''', [id]);
    if (rows.isEmpty) throw const RepoException('Participation not found');
    return _participationFromRow(rows.first);
  }

  Future<void> removeParticipant(int id) async {
    final d = await _d;
    final updated = await d.update('event_participations', {
      ...SyncStamp.now(db).tombstoneColumns(),
    }, where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
    if (updated == 0) throw const RepoException('Participation not found');
  }

  Future<ParticipationListResponse> studentParticipationHistory(int studentId) async {
    final d = await _d;
    final rows = await d.rawQuery('''
      SELECT ep.*, s.first_name, s.last_name, b.name AS batch_name,
             e.name AS event_name, e.event_date
      FROM event_participations ep
      JOIN students s ON s.id = ep.student_id
      JOIN events e ON e.id = ep.event_id
      LEFT JOIN batches b ON b.id = s.batch_id AND b.deleted_at IS NULL
      WHERE ep.student_id = ? AND ep.deleted_at IS NULL
        AND e.deleted_at IS NULL AND s.deleted_at IS NULL
      ORDER BY e.event_date DESC
    ''', [studentId]);
    return ParticipationListResponse(
      items: rows.map(_participationFromRow).toList(),
      total: rows.length,
    );
  }

  /// Map an API payload onto event columns.
  ///
  /// With [partial] set, only the keys the caller actually sent are written, so
  /// an edit that carries just one field cannot blank the rest of the event.
  ///
  /// `name` and `event_date` are NOT NULL in the schema, so they are validated
  /// rather than cast — an unchecked cast raises a type error the UI shows as
  /// gibberish, and a null date would abort the insert with a constraint error.
  Map<String, Object?> _payloadToRow(
    Map<String, dynamic> payload, {
    bool partial = false,
  }) {
    final row = <String, Object?>{};
    bool has(String key) => !partial || payload.containsKey(key);

    if (has('name')) {
      final name = (payload['name'] as String?)?.trim() ?? '';
      if (name.isEmpty) throw const RepoException('Event name is required');
      row['name'] = name;
    }
    if (has('description')) row['description'] = payload['description'];
    if (has('event_type')) {
      row['event_type'] = (payload['event_type'] as String?) ?? '';
    }
    if (has('event_date')) {
      final date = (payload['event_date'] as String?)?.trim() ?? '';
      if (date.isEmpty) throw const RepoException('Event date is required');
      row['event_date'] = date;
    }
    if (has('location')) row['location'] = payload['location'];
    if (has('batch_id')) row['batch_id'] = payload['batch_id'];
    if (has('is_active')) {
      row['is_active'] = payload['is_active'] == false ? 0 : 1;
    }
    return row;
  }

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