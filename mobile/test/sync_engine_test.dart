import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tandav_mobile/core/app_role.dart';
import 'package:tandav_mobile/database/tandav_database.dart';
import 'package:tandav_mobile/sync/sync_codec.dart';
import 'package:tandav_mobile/sync/sync_engine.dart';
import 'package:tandav_mobile/sync/sync_meta.dart';
import 'package:tandav_mobile/sync/sync_state.dart';

/// The peer these tests claim delivery to.
///
/// A sent mark is a claim about one named device, so `markSent` needs somebody
/// to name. The engine never validates the id against anything — it is only a
/// key segment — so a fixed constant stands in for "the other phone" and keeps
/// the marks comparable across a `device()` switch, which a real device id
/// could not do because it is generated per database file.
const testPeer = 'TANDAV-PEER';

/// Multi-device sync simulation. The TandavDatabase singleton is re-opened
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

  /// Switch to `name`'s database file and build a fresh engine over it.
  ///
  /// [tables] scopes that engine the way the build role does in the real app —
  /// pass `syncTablesFor(AppRole.attendance)` to get the attender's APK.
  /// Omitted, it follows [syncTables], which under `flutter test` is the full
  /// set because no `TANDAV_ROLE` is defined.
  Future<void> device(String name, {List<String>? tables}) async {
    await TandavDatabase.instance.close();
    final path = p.join(tempDir.path, '$name-$run.db');
    final db = TandavDatabase.instance;
    db.configureForTest(factory: databaseFactoryFfi, overridePath: path);
    await db.open();
    currentState = SyncState(db);
    currentEngine = SyncEngine(db, currentState, tables: tables);
  }

  String me() => TandavDatabase.instance.deviceId;

  Future<Database> open() => TandavDatabase.instance.open();

  Future<SyncDelta> outbound({Set<String> peers = const {testPeer}}) =>
      open().then((d) =>
          d.transaction((t) => currentEngine.computeOutbound(t, peers: peers)));

  Future<SyncApplyResult> applyTo(SyncDelta delta, String peerDeviceId) =>
      open().then((d) => d.transaction((t) => currentEngine.applyIncoming(
          t, delta.tables,
          peerDeviceId: peerDeviceId)));

  /// Stand-in for a transport confirming delivery. The real carriers call this
  /// after a successful Drive write / the peer's `syncDone`, and suppression of
  /// repeat sends depends entirely on it.
  Future<void> markSent(SyncDelta delta,
          {Set<String> peers = const {testPeer}}) =>
      open().then((d) =>
          d.transaction((t) => currentEngine.markDeltaSent(t, delta, peers: peers)));

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

  /// A row from a table the attender's build has no business holding, used to
  /// prove the scope filter works in both directions.
  Future<int> seedEvent(String name, {int? batchId}) async {
    final d = await open();
    return d.insert('events', {
      'name': name,
      'description': null,
      'event_type': 'annual_day',
      'event_date': '2026-12-20',
      'location': null,
      'batch_id': batchId,
      'is_active': 1,
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

  test('a peer that holds nothing forces a full send for everyone', () async {
    // The three-device case that a single `sent.<table>` mark got wrong. Two
    // owner phones sync for weeks; then the attender's phone joins. Because one
    // file serves every reader, the bundle has to satisfy whoever is furthest
    // behind — otherwise the newcomer reads a nearly-empty delta, receives none
    // of the studio's history, and both sides report a clean sync.
    const owner = 'TANDAV-OWNER2';
    const newcomer = 'TANDAV-ATTEND';

    await device('a');
    final batchId = await seedBatch('Morning');
    await seedStudent('Ravi', batchId: batchId);

    final first = await outbound(peers: const {owner});
    expect(first.rowCount, 2);
    await markSent(first, peers: const {owner});

    // Caught up with the one peer we knew about.
    expect((await outbound(peers: const {owner})).rowCount, 0);

    // A second peer appears with no mark of its own, so the floor drops back to
    // "everything" even though the first peer needs none of it.
    final rejoin = await outbound(peers: const {owner, newcomer});
    expect(rejoin.tables['batches']!.length, 1);
    expect(rejoin.tables['students']!.length, 1);

    // Delivery is recorded for both, so the next sync is quiet again.
    await markSent(rejoin, peers: const {owner, newcomer});
    expect((await outbound(peers: const {owner, newcomer})).rowCount, 0);
  });

  test('nothing is claimed delivered while no peer is known', () async {
    // The hole in the two-device version: the first phone, used for a week
    // before the second one existed, marked its rows delivered to nobody and
    // then overwrote its own file with an empty delta. The second phone arrived
    // to an empty mailbox and a first phone insisting it had sent everything.
    await device('a');
    await seedBatch('Morning');
    await seedStudent('Ravi');

    final alone = await outbound(peers: const {});
    expect(alone.rowCount, 2, reason: 'no peers means send everything');
    await markSent(alone, peers: const {});

    // No mark was written at all — not for a peer, not for the legacy
    // peer-less key — so the data is still on offer the moment somebody does
    // appear.
    expect(await countWhere('sync_state', "key LIKE 'sent.%'"), 0);
    expect((await outbound(peers: const {})).rowCount, 2);
    expect((await outbound(peers: const {testPeer})).rowCount, 2);
  });

  test('the attender scope neither stores nor sends the owner-only tables',
      () async {
    // What makes the attender's APK a data boundary rather than a hidden menu.
    // The owner's bundle carries events; the attender's engine must drop them on
    // the way in and never carry them on the way out.
    final attenderTables = syncTablesFor(AppRole.attendance);
    expect(attenderTables, isNot(contains('events')));
    expect(attenderTables, isNot(contains('event_participations')));
    expect(attenderTables, isNot(contains('monthly_progress')));
    // …while keeping everything the two allowed screens read.
    expect(attenderTables, containsAll(<String>['batches', 'students',
        'attendance', 'monthly_attendance', 'fees', 'fee_payments']));

    await device('owner');
    final ownerId = me();
    final batchId = await seedBatch('Morning');
    await seedStudent('Ravi', batchId: batchId);
    await seedEvent('Annual Day', batchId: batchId);
    final ownerDelta = await outbound();
    expect(ownerDelta.tables['events']!.length, 1,
        reason: 'the owner build does send events');

    await device('attender', tables: attenderTables);
    final applied = await applyTo(ownerDelta, ownerId);
    expect(applied.applied['students'], 1);
    expect(applied.applied['batches'], 1);
    expect(applied.applied.containsKey('events'), isFalse);
    expect(await countWhere('events', '1 = 1'), 0,
        reason: 'the event never reached the attender phone');
    // Skipping is not deleting: the rows the attender does hold are intact, and
    // the owner's events are untouched on the owner's phone.
    expect(await findStudent('Ravi'), isNotNull);

    // The send half. Seeded straight into SQLite because nothing in this build
    // can create an event — the point is that even a row that arrived some other
    // way (a restored file, a hand-edited database) is not forwarded.
    await seedEvent('Should never leave', batchId: null);
    final attenderDelta = await outbound();
    expect(attenderDelta.tables.containsKey('events'), isFalse);
    expect(attenderDelta.tables.keys, everyElement(isIn(attenderTables)));
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

  // A test covering FrameCodec / FrameAccumulator / envelope / pairingCode /
  // authToken was removed here along with `lib/sync/protocol.dart`. Those were
  // Bluetooth wire framing and the BLE pairing handshake; nothing in the app
  // uses them now that Drive is the only transport. The one piece of that file
  // still needed — `syncProtocolVersion` — moved to `sync_bundle.dart` and is
  // covered by the bundle decode tests in `cloud_sync_test.dart`.

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