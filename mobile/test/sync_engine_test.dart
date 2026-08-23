import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tandav_mobile/database/tandav_database.dart';
import 'package:tandav_mobile/sync/drive/sync_payload.dart';
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

  /// What Google Drive sync publishes: every row this device currently owns.
  Future<SyncDelta> ownedSnapshot() => open().then((d) =>
      d.transaction((t) => currentEngine.computeOutbound(t, ownedBy: me())));

  /// Serialise an owned snapshot exactly as it would be written to
  /// `Tandav/sync/devices/TANDAV-XXXX.json`.
  String publish(SyncDelta delta, String deviceId) =>
      SyncPayload.toJsonString(SyncPayload.encodeShard(
        deviceId: deviceId,
        delta: delta,
        uploadedAt: DateTime.now().toUtc().toIso8601String(),
      ));

  /// Read shard files back and merge them, as [DriveSyncManager] does.
  Future<SyncApplyResult> mergeShards(
    List<String> shardJson,
    String peerDeviceId,
  ) async {
    final combined =
        SyncPayload.combine(shardJson.map(SyncPayload.decode).toList());
    final d = await open();
    return d.transaction((t) => currentEngine.applyIncoming(t, combined,
        peerDeviceId: peerDeviceId));
  }

  Future<SyncApplyResult> applyTo(SyncDelta delta, String peerDeviceId) =>
      open().then((d) => d.transaction((t) => currentEngine.applyIncoming(
          t, delta.tables,
          peerDeviceId: peerDeviceId)));

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

  test('records flow both ways, FKs remap, and watermarks suppress repeats',
    () async {
    await device('a');
    final aId = me();
    final batchId = await seedBatch('Morning');
    await seedStudent('Ravi', batchId: batchId);

    final aDelta = await outbound();
    expect(aDelta.tables['batches']!.length, 1);
    expect(aDelta.tables['students']!.length, 1);

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
    await device('a');
    final appliedA = await applyTo(bDelta, bId);
    expect(appliedA.totalApplied, greaterThan(0));
    expect(await findStudent('Meera'), isNotNull);

    // A's next delta must NOT re-send Meera — the watermark advanced. The
    // batch row MAY be re-sent: the watermark only covers data received from
    // the peer, so our own rows in tables the peer never sent us are
    // retransmitted (the peer skips them as unchanged echoes).
    final aDelta2 = await outbound();
    expect(aDelta2.rowCount, 1);
    expect(aDelta2.tables['students'] ?? const [], isEmpty);
    expect((aDelta2.tables['batches'] ?? const []).length, 1);

    // B is not bothered by the repeated batch row.
    await device('b');
    final appliedB2 = await applyTo(aDelta2, aId);
    expect(appliedB2.totalApplied, 0);
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

  // ---------------------------------------------------------------------
  // Google Drive sync. These exercise the real transport path — owned
  // snapshot -> JSON shard file -> decode -> combine -> merge — without
  // needing a network or a Google account.
  // ---------------------------------------------------------------------

  test('Drive shards round-trip through JSON and merge both ways', () async {
    await device('a');
    final aId = me();
    final batchId = await seedBatch('Morning');
    await seedStudent('Ravi', batchId: batchId);
    final aShard = publish(await ownedSnapshot(), aId);

    // The file really is JSON, tagged with its writer.
    final aParsed = SyncPayload.decode(aShard);
    expect(aParsed.deviceId, aId);
    expect(aParsed.tables['batches']!.length, 1);
    expect(aParsed.tables['students']!.length, 1);

    await device('b');
    final bId = me();
    final applied = await mergeShards([aShard], aId);
    expect(applied.totalApplied, 2);

    // Foreign keys survived the JSON hop: local ids differ per device, so the
    // batch link must have been rebuilt from the uuid.
    final d = await open();
    final joined = await d.rawQuery('''
      SELECT s.first_name, b.name AS batch_name
      FROM students s LEFT JOIN batches b ON b.id = s.batch_id
      WHERE s.deleted_at IS NULL
    ''');
    expect(joined.first['batch_name'], 'Morning');

    // Merging the same shard again is a no-op — no duplicates.
    final again = await mergeShards([aShard], aId);
    expect(again.totalApplied, 0);
    expect((await allStudents()).length, 1);

    // B edits and publishes; A merges and adopts B's newer value.
    final bRow = await findStudent('Ravi');
    await renameStudent(bRow!['id'] as int, 'Ravi Kumar');
    final bShard = publish(await ownedSnapshot(), bId);

    await device('a');
    await mergeShards([bShard], bId);
    expect(await findStudent('Ravi Kumar'), isNotNull);
    expect(await findStudent('Ravi'), isNull);
    expect((await allStudents()).length, 1);
  });

  test('owned snapshot keeps publishing our rows after the watermark moves',
      () async {
    // This is why Drive sync publishes an owned snapshot instead of a
    // watermark delta: our shard file is overwritten on every upload, so it
    // must always carry everything we own. A delta would drop rows a device
    // that stayed offline for several syncs had not yet read.
    await device('a');
    final aId = me();
    await seedStudent('Ravi');
    final aShard = publish(await ownedSnapshot(), aId);

    await device('b');
    final bId = me();
    await mergeShards([aShard], aId);
    await seedStudent('Meera');
    final bShard = publish(await ownedSnapshot(), bId);

    await device('a');
    await mergeShards([bShard], bId); // advances A's students watermark

    // A watermark delta would now omit Ravi...
    final delta = await outbound();
    expect(delta.tables['students'] ?? const [], isEmpty);

    // ...but the owned snapshot still carries it, so a third sync still works.
    final snapshot = await ownedSnapshot();
    final names = (snapshot.tables['students'] ?? const [])
        .map((r) => r['first_name'])
        .toList();
    expect(names, contains('Ravi'));
    expect(names, isNot(contains('Meera')),
        reason: 'Meera is owned by B, so B publishes her — not A');
  });

  test('a row leaves our shard once the other device edits it', () async {
    await device('a');
    final aId = me();
    await seedStudent('Shared');
    final aShard = publish(await ownedSnapshot(), aId);

    await device('b');
    final bId = me();
    await mergeShards([aShard], aId);
    // Before B touches it the row belongs to A, so B must not publish it.
    expect((await ownedSnapshot()).tables['students'] ?? const [], isEmpty);

    await renameStudent((await findStudent('Shared'))!['id'] as int, 'Mine now');
    final bShard = publish(await ownedSnapshot(), bId);
    expect(SyncPayload.decode(bShard).tables['students']!.length, 1);

    await device('a');
    await mergeShards([bShard], bId);
    // Ownership moved to B, so A stops publishing it. Every row therefore
    // lives in exactly one shard and the union stays complete.
    expect((await ownedSnapshot()).tables['students'] ?? const [], isEmpty);
    expect((await allStudents()).length, 1);
  });

  test('tombstones travel through a Drive shard', () async {
    await device('a');
    final aId = me();
    final id = await seedStudent('Doomed');
    final liveShard = publish(await ownedSnapshot(), aId);

    await device('b');
    await mergeShards([liveShard], aId);
    expect(await countWhere('students', 'deleted_at IS NULL'), 1);

    await device('a');
    await tombstoneStudent(id);
    final deletedShard = publish(await ownedSnapshot(), aId);

    await device('b');
    await mergeShards([deletedShard], aId);
    expect(await countWhere('students', 'deleted_at IS NULL'), 0);
    expect(await countWhere('students', 'deleted_at IS NOT NULL'), 1);
  });

  test('combine keeps the newest copy when a row appears in two shards',
      () async {
    // A stale shard from the previous owner and a fresh one from the new owner
    // both describe the same record; the newer must win regardless of order.
    Map<String, Object?> row(String name, String updatedAt, String device) => {
          'first_name': name,
          'sync_uuid': 'uuid-1',
          'device_id': device,
          'updated_at': updatedAt,
          'deleted_at': null,
        };

    final stale = ParsedPayload(
      deviceId: 'TANDAV-A001',
      uploadedAt: '',
      tables: {
        'students': [row('Old', '2026-08-01T10:00:00.000Z', 'TANDAV-A001')],
      },
    );
    final fresh = ParsedPayload(
      deviceId: 'TANDAV-B002',
      uploadedAt: '',
      tables: {
        'students': [row('New', '2026-08-02T10:00:00.000Z', 'TANDAV-B002')],
      },
    );

    for (final order in [
      [stale, fresh],
      [fresh, stale],
    ]) {
      final merged = SyncPayload.combine(order);
      expect(merged['students']!.length, 1);
      expect(merged['students']!.first['first_name'], 'New');
    }

    // Exact timestamp tie: the higher device id wins on both devices.
    final tieA = ParsedPayload(deviceId: 'TANDAV-A001', uploadedAt: '', tables: {
      'students': [row('FromA', '2026-08-03T10:00:00.000Z', 'TANDAV-A001')],
    });
    final tieB = ParsedPayload(deviceId: 'TANDAV-B002', uploadedAt: '', tables: {
      'students': [row('FromB', '2026-08-03T10:00:00.000Z', 'TANDAV-B002')],
    });
    expect(SyncPayload.combine([tieA, tieB])['students']!.first['first_name'],
        'FromB');
    expect(SyncPayload.combine([tieB, tieA])['students']!.first['first_name'],
        'FromB');
  });

  test('shards never carry credentials or device-local file paths', () async {
    await device('a');
    final aId = me();
    final id = await seedStudent('Photographed');
    final d = await open();
    await d.update('students', {'photo_url': '/data/user/0/photos/9.jpg'},
        where: 'id = ?', whereArgs: [id]);

    final shard = publish(await ownedSnapshot(), aId);

    // A device-local absolute path is meaningless (and mildly private) on the
    // other device, so it is stripped. Being *absent* rather than null also
    // means merging leaves each device's own photo path untouched.
    expect(shard.contains('photo_url'), isFalse);
    expect(shard.contains('/data/user/0/photos'), isFalse);

    // The users table holds password hashes and is not a syncable table at
    // all, so no credential can reach Drive by construction.
    expect(SyncCodec.applyOrder, isNot(contains('users')));
    for (final table in SyncCodec.applyOrder) {
      for (final column in SyncCodec.columnsFor(table)) {
        expect(
          RegExp('password|secret|token|credential|private_key',
                  caseSensitive: false)
              .hasMatch(column),
          isFalse,
          reason: '$table.$column looks like a credential',
        );
      }
    }
  });

  test('a newer sync file format is refused with a clear message', () {
    expect(
      () => SyncPayload.decode('{"formatVersion": 99, "tables": {}}'),
      throwsA(isA<FormatException>()),
    );
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