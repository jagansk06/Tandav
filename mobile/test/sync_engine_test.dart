import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tandav_mobile/database/tandav_database.dart';
import 'package:tandav_mobile/sync/protocol.dart';
import 'package:tandav_mobile/sync/sync_codec.dart';
import 'package:tandav_mobile/sync/sync_engine.dart';
import 'package:tandav_mobile/sync/sync_meta.dart';
import 'package:tandav_mobile/sync/sync_state.dart';

/// Two-device sync simulation. The TandavDatabase singleton is re-opened
/// against a different SQLite file per device — switching the file is
/// equivalent to moving to the other phone. The engine/state are built fresh
/// each time the file is switched.
void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  int run = 0;
  late SyncEngine currentEngine;
  late SyncState currentState;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tandav_sync_test_');
  });

  setUp(() {
    run++;
  });

  tearDownAll(() async {
    await TandavDatabase.instance.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> device(String name) async {
    await TandavDatabase.instance.close();
    final path = p.join(tempDir.path, '$name-$run.db');
    final db = TandavDatabase.instance;
    db.configureForTest(factory: databaseFactoryFfi, overridePath: path);
    await db.open();
    currentState = SyncState(db);
    currentEngine = SyncEngine(db, currentState);
  }

  String me() => TandavDatabase.instance.deviceId;

  Future<Database> open() => TandavDatabase.instance.open();

  Future<SyncDelta> outbound() =>
      open().then((d) => d.transaction((t) => currentEngine.computeOutbound(t)));

  Future<SyncApplyResult> applyTo(SyncDelta delta, String peerDeviceId) =>
      open().then((d) => d.transaction((t) => currentEngine.applyIncoming(
          t, delta.tables,
          peerDeviceId: peerDeviceId)));

  /// Stand-in for a transport confirming delivery. The real carriers call this
  /// after a successful Drive write / the peer's `syncDone`, and suppression of
  /// repeat sends depends entirely on it.
  Future<void> markSent(SyncDelta delta) => open().then(
      (d) => d.transaction((t) => currentEngine.markDeltaSent(t, delta)));

  Future<int> seedStudent(String name, {int? batchId}) async {
    final d = await open();
    return d.insert('students', {
      'first_name': name,
      'last_name': '',
      'gender': '',
      'dob': null,
      'phone': '',
      'email': null,
      'address': null,
      'emergency_contact_name': null,
      'emergency_contact_phone': null,
      'batch_id': batchId,
      'monthly_fee': 500.0,
      'join_date': '2026-08-01',
      'is_active': 1,
      'photo_url': null,
      'notes': null,
      ...SyncStamp.now(TandavDatabase.instance).columns(),
    });
  }

  Future<int> seedBatch(String name) async {
    final d = await open();
    return d.insert('batches', {
      'name': name,
      'dance_style': '',
      'level': '',
      'schedule': '',
      'monthly_fee': 0,
      'is_active': 1,
      'notes': null,
      ...SyncStamp.now(TandavDatabase.instance).columns(),
    });
  }

  Future<void> renameStudent(int id, String newName) async {
    final d = await open();
    await d.update('students', {
      'first_name': newName,
      ...SyncStamp.now(TandavDatabase.instance).touchColumns(),
    }, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> tombstoneStudent(int id) async {
    final d = await open();
    await d.update('students', {
      ...SyncStamp.now(TandavDatabase.instance).tombstoneColumns(),
    }, where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, Object?>?> findStudent(String name) async {
    final d = await open();
    final rows = await d.query('students',
        where: 'first_name = ? AND deleted_at IS NULL',
        whereArgs: [name],
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> allStudents() async {
    final d = await open();
    return d.query('students');
  }

  Future<int> countWhere(String table, String where) async {
    final d = await open();
    return Sqflite.firstIntValue(
            await d.rawQuery('SELECT COUNT(*) FROM $table WHERE $where')) ??
        0;
  }

  test('records flow both ways, FKs remap, and confirmed sends suppress repeats',
    () async {
    await device('a');
    final aId = me();
    final batchId = await seedBatch('Morning');
    await seedStudent('Ravi', batchId: batchId);

    final aDelta = await outbound();
    expect(aDelta.tables['batches']!.length, 1);
    expect(aDelta.tables['students']!.length, 1);
    await markSent(aDelta);

    await device('b');
    final bId = me();
    expect(bId, isNot(aId));
    final appliedB = await applyTo(aDelta, aId);
    expect(appliedB.totalApplied, 2);

    // FK remapped: Ravi's local batch_id points at B's local batch row.
    final d = await open();
    final rows = await d.rawQuery('''
      SELECT s.*, b.name AS batch_name
      FROM students s LEFT JOIN batches b ON b.id = s.batch_id
      WHERE s.first_name = 'Ravi'
    ''');
    expect(rows.first['batch_name'], 'Morning');
    expect(rows.first['sync_uuid'], isNotNull);
    expect(rows.first['sync_uuid'], isNotEmpty);

    // B creates a second student, syncs back to A.
    await seedStudent('Meera');
    final bDelta = await outbound();
    await markSent(bDelta);
    await device('a');
    final appliedA = await applyTo(bDelta, bId);
    expect(appliedA.totalApplied, greaterThan(0));
    expect(await findStudent('Meera'), isNotNull);

    // A's batch row is not re-sent: A delivered it and marked it so.
    //
    // Meera IS offered back once. That is the deliberate price of filtering
    // outbound by "what we have delivered" rather than "what we have received":
    // A has never *sent* Meera, so A offers her. Sending one redundant row is
    // harmless — B skips it as an unchanged echo — whereas the reverse mistake
    // silently loses edits forever, which is the bug this design replaced.
    final aDelta2 = await outbound();
    expect(aDelta2.tables['batches'] ?? const [], isEmpty);
    expect((aDelta2.tables['students'] ?? const []).length, 1);

    await device('b');
    final appliedB2 = await applyTo(aDelta2, aId);
    expect(appliedB2.totalApplied, 0, reason: 'B already has Meera');

    // The echo terminates — this is the property that actually matters, because
    // a re-send that never stopped would be an infinite loop between the two
    // phones.
    await device('a');
    await markSent(aDelta2);
    expect((await outbound()).rowCount, 0);
  });

  test('last-write-wins by updated_at', () async {
    await device('a');
    final aId = me();
    final aid = await seedStudent('Old');
    await renameStudent(aid, 'Won-on-A');
    final aDelta = await outbound();

    await device('b');
    final bId = me();
    await applyTo(aDelta, aId);
    final bRow = await findStudent('Won-on-A');
    final bid = bRow!['id'] as int;

    // B edits the same student later -> B's version must win on both sides.
    await renameStudent(bid, 'Won-on-B');
    final bDelta = await outbound();
    await device('a');
    final applied = await applyTo(bDelta, bId);
    expect(applied.totalApplied, greaterThan(0));

    expect((await findStudent('Won-on-B'))!['first_name'], 'Won-on-B');
    expect(await findStudent('Won-on-A'), isNull);
  });

  test('LWW tie on identical timestamps uses the higher device id', () async {
    await device('a');
    final aId = me();
    await seedStudent('Self');
    final stampA = SyncStamp.now(TandavDatabase.instance);
    final t = stampA.updatedAt;
    await open().then((d) => d.update('students', {...stampA.touchColumns()}));
    final aDelta = await outbound();

    await device('b');
    final bId = me();
    await applyTo(aDelta, aId); // b learns the row; b's watermark = t

    // Both devices edit the exact same millisecond (t).
    final echoA = SyncStamp(uuid: stampA.uuid, deviceId: aId, updatedAt: t);
    final echoB = SyncStamp(uuid: stampA.uuid, deviceId: bId, updatedAt: t);
    await device('a');
    await open().then((d) => d
        .update('students', {'first_name': 'Self', ...echoA.touchColumns()}));
    await device('b');
    await open().then((d) => d.update('students',
        {'first_name': 'Clash', ...echoB.touchColumns()}));

    for (var round = 0; round < 3; round++) {
      await device('a');
      final dA = await outbound();
      await device('b');
      await applyTo(dA, aId);
      final dB = await outbound();
      await device('a');
      await applyTo(dB, bId);
    }

    final winner = aId.compareTo(bId) > 0 ? 'Self' : 'Clash';
    for (final name in ['a', 'b']) {
      await device(name);
      final rows = await allStudents();
      expect(rows.length, 1, reason: 'no dupes on $name');
      expect(rows.first['first_name'], winner,
          reason: 'both devices show the higher device id\'s edit');
    }
  });

  test('deletions tombstone and reach the peer', () async {
    await device('a');
    final aId = me();
    final aid = await seedStudent('Doomed');
    final aDelta = await outbound();

    await device('b');
    await applyTo(aDelta, aId);
    expect(await countWhere('students', 'deleted_at IS NULL'), 1);

    await device('a');
    await tombstoneStudent(aid);
    final aDelta2 = await outbound();
    await device('b');
    await applyTo(aDelta2, aId);

    expect(await countWhere('students', 'deleted_at IS NULL'), 0);
    expect(await countWhere('students', 'deleted_at IS NOT NULL'), 1);
  });

  test('natural keys merge independently created batches', () async {
    await device('a');
    final aId = me();
    await seedStudent('Dupe');
    await seedBatch('Common');
    final aDelta = await outbound();

    await device('b');
    final bId = me();
    await seedStudent('Dupe');
    await seedBatch('Common');
    await applyTo(aDelta, aId);
    final bDelta = await outbound();
    await device('a');
    await applyTo(bDelta, bId);

    expect((await allStudents()).length, 2);
    expect(await countWhere('batches', 'deleted_at IS NULL'), 1);
  });

  test('FrameCodec reassembles large payloads; protocol helpers behave',
      () async {
    final rng = Random(7);
    final payload = List<int>.generate(5000, (_) => rng.nextInt(255) + 1);
    final packets = FrameCodec.encode(payload);

    final acc = FrameAccumulator();
    Uint8List? reassembled;
    for (final packet in packets) {
      final (frame, done) = FrameCodec.feed(acc, packet);
      if (done) {
        reassembled = frame;
        break;
      }
    }
    expect(reassembled, isNotNull);
    expect(reassembled!.length, payload.length);
    expect(reassembled, equals(payload));

    final msg = envelope(SyncMsgType.hello, {'deviceId': 'TANDAV-X1'});
    expect(typeOf(msg), SyncMsgType.hello);

    final codeA = pairingCode('TANDAV-A7F3', 'TANDAV-B291');
    final codeB = pairingCode('TANDAV-B291', 'TANDAV-A7F3');
    expect(codeA, codeB);
    expect(RegExp(r'^\d{6}$').hasMatch(codeA), true);

    final token = authToken('TANDAV-A7F3', 'secret-x', 'nonce-1');
    expect(token, authToken('TANDAV-A7F3', 'secret-x', 'nonce-1'));
    expect(token, isNot(authToken('TANDAV-A7F3', 'secret-x', 'nonce-2')));
    expect(token, isNot(authToken('TANDAV-A7F3', 'secret-y', 'nonce-1')));
  });

  test('SyncCodec round trips payloads with FKs', () {
    final row = <String, Object?>{
      'first_name': 'a',
      '_table': 'students',
      '_fk': {'batches': 'uuid-1'},
    };
    final json = SyncCodec.encodeRowsToJson('students', [row]);
    final (table, rows) = SyncCodec.decodeRows(json);
    expect(table, 'students');
    expect(rows.first['first_name'], 'a');
    expect(rows.first['_fk'], {'batches': 'uuid-1'});
  });
}