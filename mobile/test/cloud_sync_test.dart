import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tandav_mobile/core/app_role.dart';
import 'package:tandav_mobile/database/tandav_database.dart';
import 'package:tandav_mobile/sync/cloud_sync.dart';
import 'package:tandav_mobile/sync/sync_bundle.dart';
import 'package:tandav_mobile/sync/sync_engine.dart';
import 'package:tandav_mobile/sync/sync_mailbox.dart';
import 'package:tandav_mobile/sync/sync_meta.dart';
import 'package:tandav_mobile/sync/sync_state.dart';

/// In-memory stand-in for Google Drive.
///
/// This is the whole point of the [SyncMailbox] abstraction: the mailbox sync
/// path can be proven correct on a laptop with no network, no Google account
/// and no phone. The real [DriveMailbox] only has to move bytes; every rule
/// about *what* gets moved is exercised here.
class FakeMailbox extends SyncMailbox {
  final Map<String, String> files = {};
  final Map<String, DateTime> times = {};

  bool connected = true;
  @override
  String? accountLabel = 'studio@example.com';

  int writeCount = 0;
  int readCount = 0;

  /// When set, the next [writeOwn] throws — simulating a dropped connection
  /// mid-upload.
  String? failNextWriteWith;

  /// When set, [list] never completes — a Drive call that hangs rather than
  /// failing, which is the case that used to wedge the sync screen.
  ///
  /// Deliberately a [Completer] that is never completed rather than a
  /// [Future.delayed]: it leaves no pending timer for the test runner to trip
  /// over, and no real time is spent waiting.
  bool hangOnList = false;
  final _hang = Completer<List<MailboxEntry>>();

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<bool> connectSilently() async => connected;

  @override
  Future<void> disconnect() async => connected = false;

  @override
  Future<List<MailboxEntry>> list() async {
    if (!connected) throw MailboxException('Not connected', isAuthFailure: true);
    if (hangOnList) return _hang.future;
    return files.keys
        .map((name) => MailboxEntry(
              id: name,
              name: name,
              modifiedAt: times[name],
              sizeBytes: files[name]!.length,
            ))
        .toList();
  }

  @override
  Future<String> read(MailboxEntry entry) async {
    readCount++;
    final body = files[entry.id];
    if (body == null) throw MailboxException('File vanished from the mailbox.');
    return body;
  }

  @override
  Future<void> writeOwn(String deviceId, String contents) async {
    final fail = failNextWriteWith;
    if (fail != null) {
      failNextWriteWith = null;
      throw MailboxException(fail);
    }
    writeCount++;
    final name = SyncMailbox.fileNameFor(deviceId);
    files[name] = contents;
    times[name] = DateTime.now().toUtc();
  }

  @override
  Future<void> delete(MailboxEntry entry) async {
    files.remove(entry.id);
    times.remove(entry.id);
  }

  /// Drop a file in as if a third phone had written it.
  void plant(String deviceId, String contents) {
    final name = SyncMailbox.fileNameFor(deviceId);
    files[name] = contents;
    times[name] = DateTime.now().toUtc();
  }
}

void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  int run = 0;
  late CloudSyncManager cloud;
  late FakeMailbox mailbox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tandav_cloud_test_');
  });

  setUp(() {
    run++;
    mailbox = FakeMailbox();
  });

  tearDownAll(() async {
    await TandavDatabase.instance.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Switch to a device: re-point the database singleton at that device's file
  /// and rebuild the sync stack around it. Every device shares one [mailbox],
  /// exactly as the studio's phones share one Drive account.
  ///
  /// [tables] scopes the engine the way `TANDAV_ROLE` does in a real build —
  /// pass `syncTablesFor(AppRole.attendance)` to stand up the attender's APK.
  Future<void> device(String name,
      {Duration? syncTimeout, List<String>? tables}) async {
    await TandavDatabase.instance.close();
    final db = TandavDatabase.instance;
    db.configureForTest(
      factory: databaseFactoryFfi,
      overridePath: p.join(tempDir.path, '$name-$run.db'),
    );
    await db.open();
    final state = SyncState(db);
    cloud = CloudSyncManager(
      db: db,
      state: state,
      engine: SyncEngine(db, state, tables: tables),
      mailbox: mailbox,
      syncTimeout: syncTimeout ?? const Duration(seconds: 90),
    );
  }

  String me() => TandavDatabase.instance.deviceId;

  Future<Database> open() => TandavDatabase.instance.open();

  /// Timestamps drive last-write-wins, so tests that depend on ordering must
  /// not land two writes in the same instant.
  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 5));

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

  Future<int> seedStudent(String name, {int? batchId, String? updatedAt}) async {
    final d = await open();
    final instance = TandavDatabase.instance;
    // A caller-supplied [updatedAt] lets a test pretend the device clock is
    // wrong, which is the only way to reproduce cross-device clock skew.
    final stamp = updatedAt == null
        ? SyncStamp.now(instance)
        : SyncStamp(
            uuid: TandavDatabase.generateSyncUuid(),
            deviceId: instance.deviceId,
            updatedAt: updatedAt,
          );
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
      ...stamp.columns(),
    });
  }

  /// A row from a table the attender's build must never hold or forward.
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
    await d.update(
      'students',
      {
        'first_name': newName,
        ...SyncStamp.now(TandavDatabase.instance).touchColumns(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> tombstoneStudent(int id) async {
    final d = await open();
    await d.update(
      'students',
      SyncStamp.now(TandavDatabase.instance).tombstoneColumns(),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Map<String, Object?>?> findStudent(String name) async {
    final d = await open();
    final rows = await d.query(
      'students',
      where: 'first_name = ? AND deleted_at IS NULL',
      whereArgs: [name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  test('file naming round-trips and ignores foreign files', () {
    expect(SyncMailbox.fileNameFor('TANDAV-4F2A'), 'tandav-TANDAV-4F2A.json');
    expect(
      SyncMailbox.deviceIdFromFileName('tandav-TANDAV-4F2A.json'),
      'TANDAV-4F2A',
    );
    expect(SyncMailbox.deviceIdFromFileName('holiday-photo.jpg'), isNull);
    expect(SyncMailbox.deviceIdFromFileName('tandav-.json'), isNull);
    expect(SyncMailbox.deviceIdFromFileName('tandav-TANDAV-1.txt'), isNull);
  });

  test('records travel through the mailbox and foreign keys remap', () async {
    await device('a');
    final aId = me();
    final batchId = await seedBatch('Morning');
    await seedStudent('Ravi', batchId: batchId);

    final pushed = await cloud.syncNow();
    expect(pushed.ok, isTrue);
    expect(pushed.sent, 2);
    expect(pushed.applied, 0);
    expect(pushed.peerDeviceId, isNull); // nobody else has synced yet
    expect(mailbox.files.keys, contains(SyncMailbox.fileNameFor(aId)));

    await device('b');
    final bId = me();
    expect(bId, isNot(aId));

    final pulled = await cloud.syncNow();
    expect(pulled.ok, isTrue);
    expect(pulled.applied, 2);
    expect(pulled.peerDeviceId, aId);
    expect(await cloud.cloudPeerId, aId);

    // The student's local batch_id was rewritten to B's own batch row id.
    final d = await open();
    final joined = await d.rawQuery('''
      SELECT s.first_name, b.name AS batch_name
      FROM students s LEFT JOIN batches b ON b.id = s.batch_id
      WHERE s.first_name = 'Ravi'
    ''');
    expect(joined.single['batch_name'], 'Morning');

    // Nothing new to do on an immediate re-sync.
    final again = await cloud.syncNow();
    expect(again.ok, isTrue);
    expect(again.applied, 0);
  });

  test('local edits are never swallowed by the peer being ahead', () async {
    // This locks in the upload-before-merge ordering. Merging first advances
    // the watermark past our own unsent rows, which would silently drop them.
    await device('a');
    final aId = me();
    await seedBatch('Morning');
    await cloud.syncNow();

    await device('b');
    final bId = me();
    await cloud.syncNow(); // learns Morning
    await tick();
    await seedStudent('Meera');
    await cloud.syncNow(); // Meera is now waiting in the mailbox

    await device('a');
    await cloud.syncNow(); // A merges Meera -> students watermark = Meera's time
    expect(await findStudent('Meera'), isNotNull);

    await tick();
    await seedStudent('Ravi'); // A's own new row, older than what B sends next

    await device('b');
    await tick();
    await seedStudent('Nina');
    await cloud.syncNow(); // B uploads Meera + Nina (newer than Ravi)

    await device('a');
    final aRun = await cloud.syncNow();
    expect(aRun.ok, isTrue);
    expect(await findStudent('Nina'), isNotNull);
    // The critical assertion: Ravi went out in the same run.
    expect(aRun.sent, greaterThan(0));

    await device('b');
    await cloud.syncNow();
    expect(await findStudent('Ravi'), isNotNull,
        reason: 'A local edit was lost because the merge ran before the '
            'upload snapshot');
    expect(bId, isNot(aId));
  });

  test('last-write-wins resolves an edit made on both devices', () async {
    await device('a');
    final studentId = await seedStudent('Original');
    await cloud.syncNow();

    await device('b');
    await cloud.syncNow();
    final onB = await findStudent('Original');
    expect(onB, isNotNull);

    // A edits first, B edits later; B must win on both devices.
    await device('a');
    await tick();
    await renameStudent(studentId, 'Edited-on-A');
    await cloud.syncNow();

    await device('b');
    await tick();
    await renameStudent(onB!['id'] as int, 'Edited-on-B');
    await cloud.syncNow();

    await device('a');
    await cloud.syncNow();
    expect(await findStudent('Edited-on-B'), isNotNull);
    expect(await findStudent('Edited-on-A'), isNull);

    await device('b');
    await cloud.syncNow();
    expect(await findStudent('Edited-on-B'), isNotNull);
  });

  test('deletions propagate as tombstones', () async {
    await device('a');
    final studentId = await seedStudent('Leaving');
    await cloud.syncNow();

    await device('b');
    await cloud.syncNow();
    expect(await findStudent('Leaving'), isNotNull);

    await device('a');
    await tick();
    await tombstoneStudent(studentId);
    await cloud.syncNow();

    await device('b');
    await cloud.syncNow();
    expect(await findStudent('Leaving'), isNull);
    final d = await open();
    final rows = await d.query(
      'students',
      where: 'first_name = ? AND deleted_at IS NOT NULL',
      whereArgs: ['Leaving'],
    );
    expect(rows, hasLength(1), reason: 'tombstone row must be kept');
  });

  test('three devices share the account and a fourth is refused', () async {
    await device('a');
    final aId = me();
    await seedBatch('Morning');
    await cloud.syncNow();

    await device('b');
    await cloud.syncNow();
    expect(await cloud.cloudPeerId, aId);

    // The attender's phone signs in. Three devices is the shape the studio
    // actually bought — two owners and the attender — so this must be adopted,
    // not refused. The two-device build turned this file away.
    mailbox.plant('TANDAV-9ZZZ', SyncBundle.encode(
      deviceId: 'TANDAV-9ZZZ',
      delta: SyncDelta(),
    ));
    final three = await cloud.syncNow();
    expect(three.ok, isTrue, reason: three.message);
    expect(three.peerDeviceIds, containsAll(<String>[aId, 'TANDAV-9ZZZ']));
    expect(await cloud.knownPeers(), hasLength(CloudSyncManager.maxPeers));
    // One name is still exposed for the screens that show a single "other
    // device", and it stays the first device adopted rather than shuffling.
    expect(three.peerDeviceId, aId);

    // A fourth signs into the same account. B's slots are full, so the newcomer
    // is ignored rather than swapped in: the devices B already knows keep
    // syncing normally while the extra one is sorted out.
    mailbox.plant('TANDAV-7YYY', SyncBundle.encode(
      deviceId: 'TANDAV-7YYY',
      delta: SyncDelta(),
    ));
    final ignored = await cloud.syncNow();
    expect(ignored.ok, isTrue, reason: ignored.message);
    expect(ignored.peerDeviceIds, isNot(contains('TANDAV-7YYY')));
    expect(await cloud.knownPeers(), hasLength(CloudSyncManager.maxPeers));

    // A brand-new device cannot tell which of the four are its partners, so it
    // refuses rather than guessing — and names the FILES, because "delete one
    // of these in Drive" is the remedy and a bare TANDAV-XXXX is not something
    // the customer can point at in a folder listing.
    await device('d');
    final fresh = await cloud.syncNow();
    expect(fresh.ok, isFalse);
    expect(fresh.message, contains('4 other devices'));
    expect(fresh.message, contains('Tandav Sync'));
    expect(fresh.message, contains(SyncMailbox.fileNameFor('TANDAV-9ZZZ')));
    expect(fresh.message, contains(SyncMailbox.fileNameFor('TANDAV-7YYY')));
    expect(fresh.message, contains(SyncMailbox.fileNameFor(aId)));
  });

  test('the attender build never puts owner-only rows in the mailbox', () async {
    // The engine tests prove the scope filter; this proves it holds on the
    // artifact that actually leaves the phone. A bundle is a plain JSON file in
    // someone's Drive, so "the attender does not hold events" has to be true of
    // the file, not only of the screens.
    await device('owner');
    final ownerId = me();
    final batchId = await seedBatch('Morning');
    await seedStudent('Ravi', batchId: batchId);
    await seedEvent('Annual Day', batchId: batchId);
    await cloud.syncNow();
    final ownerFile = SyncMailbox.fileNameFor(ownerId);
    expect(SyncBundle.decode(mailbox.files[ownerFile]!).tables.keys,
        contains('events'),
        reason: 'the owner build does send events — otherwise this proves '
            'nothing');

    await device('attender', tables: syncTablesFor(AppRole.attendance));
    final attenderId = me();
    final joined = await cloud.syncNow();
    expect(joined.ok, isTrue, reason: joined.message);
    expect(joined.applied, 2, reason: 'the batch and the student, not the event');
    final d = await open();
    expect(await d.query('events'), isEmpty,
        reason: "the owner's bundle carried an event and it was skipped");
    expect(await findStudent('Ravi'), isNotNull);

    // And the send half, with a row planted straight into SQLite because
    // nothing in this build can create one. Even a row that arrived some other
    // way — a restored file, a hand-edited database — is not forwarded.
    await seedEvent('Should never leave');
    final second = await cloud.syncNow();
    expect(second.ok, isTrue, reason: second.message);
    expect(
      SyncBundle.decode(mailbox.files[SyncMailbox.fileNameFor(attenderId)]!)
          .tables
          .keys,
      isNot(contains('events')),
    );
    expect(await cloud.pendingByTable(), isNot(contains('events')));
  });

  test('a failed upload changes nothing locally', () async {
    await device('a');
    await seedBatch('Morning');
    await seedStudent('Ravi');

    mailbox.failNextWriteWith = 'No internet connection.';
    final failed = await cloud.syncNow();
    expect(failed.ok, isFalse);
    expect(failed.message, 'No internet connection.');
    expect(mailbox.files, isEmpty);
    expect(await cloud.lastCloudSyncAt, isNull);

    // The retry sends exactly the same delta.
    final retried = await cloud.syncNow();
    expect(retried.ok, isTrue);
    expect(retried.sent, 2);
  });

  test('a damaged file fails cleanly and nothing is half-applied', () async {
    await device('b');
    await seedBatch('Evening');
    await seedStudent('Local-Only');
    final before = await cloud.pendingRowCount();
    expect(before, 2);

    // B's pair uploaded a truncated file (killed app, dropped connection…).
    //
    // Seeded through the singular `kCloudPeerId` on purpose. That is the key
    // written by every build before three devices were supported, so a phone
    // upgrading today still has it and nothing else. Reading it back proves
    // `knownPeers()` folds the legacy key into the list instead of treating an
    // established peer as a stranger — which would have made the first sync
    // after an update either re-adopt or refuse the phone it had been syncing
    // with all along.
    mailbox.plant('TANDAV-8QQQ', '{ this is not json');
    await SyncState(TandavDatabase.instance)
        .write(CloudSyncManager.kCloudPeerId, 'TANDAV-8QQQ');

    final result = await cloud.syncNow();
    expect(result.ok, isFalse);
    expect(result.message, contains('damaged'));

    // Our own data is untouched and the run did not count as a successful sync.
    expect(await findStudent('Local-Only'), isNotNull);
    expect(await cloud.lastCloudSyncAt, isNull);

    // Our upload happened before the damaged file was read, and a bad file on
    // the peer's side cannot un-send it — so those rows are genuinely delivered
    // and must NOT be queued again.
    expect(mailbox.files, contains(SyncMailbox.fileNameFor(me())));
    expect(await cloud.pendingRowCount(), 0);
  });

  test('bundle encoding rejects incompatible and malformed input', () {
    expect(() => SyncBundle.decode('not json'), throwsA(isA<SyncBundleException>()));
    expect(() => SyncBundle.decode('[]'), throwsA(isA<SyncBundleException>()));
    expect(() => SyncBundle.decode('{"tandav":1}'),
        throwsA(isA<SyncBundleException>()));
    expect(
      () => SyncBundle.decode('{"tandav":999,"deviceId":"X","protocol":1,'
          '"tables":{}}'),
      throwsA(isA<SyncBundleException>()),
    );

    final empty = SyncBundle.decode(
      SyncBundle.encode(deviceId: 'TANDAV-0001', delta: SyncDelta()),
    );
    expect(empty.deviceId, 'TANDAV-0001');
    expect(empty.isEmpty, isTrue);
    expect(empty.rowCount, 0);
  });

  test('a peer with a fast clock cannot strand our local edits', () async {
    // Regression guard for the worst bug this sync had. Outbound rows used to
    // be filtered by the mark of what we had RECEIVED from the peer, so once a
    // peer with a fast clock sent us a row stamped in the future, every local
    // edit we made before real time caught up sorted below that mark and became
    // permanently unsendable. Phone clocks disagree by minutes routinely, and
    // one of these two phones belongs to someone else entirely.
    await device('b');
    final future = DateTime.now()
        .toUtc()
        .add(const Duration(hours: 1))
        .toIso8601String();
    await seedStudent('From-Fast-Phone', updatedAt: future);
    await cloud.syncNow();

    await device('a');
    await cloud.syncNow();
    expect(await findStudent('From-Fast-Phone'), isNotNull);

    // A edits using its own correct clock, so this row is timestamped an hour
    // BEHIND the row A just merged.
    await seedStudent('Added-On-A');
    final run = await cloud.syncNow();
    expect(run.ok, isTrue);
    expect(run.sent, greaterThan(0),
        reason: 'a local edit older than the peer\'s newest row must still go '
            'out, or it is lost forever');

    await device('b');
    await cloud.syncNow();
    expect(await findStudent('Added-On-A'), isNotNull,
        reason: 'the edit never reached the other phone');

    // The subtle repeat of the same bug: A merged a row stamped an hour ahead,
    // so if that foreign timestamp were allowed to become A's "delivered" mark,
    // A's NEXT edit would sort below it and be stranded just the same. Marking
    // is clamped to A's own clock precisely to stop that.
    await device('a');
    await tick();
    await seedStudent('Second-Edit-On-A');
    final second = await cloud.syncNow();
    expect(second.sent, greaterThan(0),
        reason: 'a foreign future timestamp poisoned our delivered mark');

    await device('b');
    await cloud.syncNow();
    expect(await findStudent('Second-Edit-On-A'), isNotNull);
  });

  test('a replaced phone is adopted into a free slot and gets the history',
      () async {
    // The scenario this guards: one of the studios loses or factory-resets its
    // phone. Tandav comes back with a brand-new TANDAV-XXXX, so the id the
    // surviving phone remembers will never appear again. With a slot free the
    // newcomer is simply adopted, and the *per-peer* delivered marks are what
    // make that safe: the surviving phone has no mark for a device it has never
    // met, so its floor drops to "everything" and the studio's history goes out
    // on that very first sync.
    //
    // The two-device build got this wrong in the worst available way. One mark
    // per table meant "already delivered" was a claim about the *old* phone, so
    // the replacement was adopted, both devices reported a clean sync, and only
    // rows edited from that moment onwards ever reached it. Nothing on screen
    // said so, and the two symptoms it produces ("the phone is not sending" and
    // "the iPhone is not sending") look like two faults and are one.
    await device('a');
    final aId = me();
    await seedBatch('Morning');
    await cloud.syncNow();

    await device('b');
    await cloud.syncNow(); // adopts A, learns Morning
    expect(await cloud.cloudPeerId, aId);
    await tick();
    await seedStudent('Ravi');
    await cloud.syncNow(); // B delivers Morning + Ravi to A
    await cloud.syncNow(); // …and B's own file drains to empty
    final bFile = SyncMailbox.fileNameFor(me());
    expect(await cloud.pendingRowCount(), 0);
    expect(SyncBundle.decode(mailbox.files[bFile]!).rowCount, 0);

    // Phone A is gone for good: its bundle is removed from the account, and a
    // replacement phone signs in and syncs under a different id.
    mailbox.files.remove(SyncMailbox.fileNameFor(aId));
    mailbox.times.remove(SyncMailbox.fileNameFor(aId));
    await device('c');
    final cId = me();
    expect(cId, isNot(aId));
    await seedBatch('Evening');
    final blank = await cloud.syncNow();
    expect(blank.ok, isTrue, reason: blank.message);
    expect(blank.applied, 0,
        reason: 'a drained delta holds no copy of anything — which is why the '
            'floor, not the file, has to do the work below');

    await device('b');
    final adopted = await cloud.syncNow();
    expect(adopted.ok, isTrue, reason: adopted.message);
    expect(adopted.peerDeviceIds, contains(cId));
    expect(adopted.sent, 2,
        reason: 'C holds nothing, so the floor drops back to "everything" even '
            'though A was fully caught up');
    // The dead id is still remembered. It costs a slot, and "Forget the other
    // device" is how that slot comes back, but it no longer blocks anything.
    expect(await cloud.knownPeers(), containsAll(<String>[aId, cId]));

    final onB = await open();
    expect(
      await onB.query('batches', where: 'name = ?', whereArgs: ['Evening']),
      hasLength(1),
      reason: "the replacement phone's records never arrived",
    );

    await device('c');
    final backfilled = await cloud.syncNow();
    expect(backfilled.ok, isTrue, reason: backfilled.message);
    expect(await findStudent('Ravi'), isNotNull);
    final onC = await open();
    expect(
      await onC.query('batches', where: 'name = ?', whereArgs: ['Morning']),
      hasLength(1),
      reason: 'a per-table sent mark claimed the new device already had this',
    );
  });

  test('peers that have all vanished are recoverable by forgetting them',
      () async {
    // The remaining stuck state, now that a replacement fits in a spare slot:
    // every slot is held by a device that will never write again. Then there is
    // nowhere to put the newcomer, and the app must say which devices it is
    // waiting for and what to press — not blame device count, which is both
    // untrue and unactionable.
    await device('a');
    final aId = me();
    await seedBatch('Morning');
    await cloud.syncNow();

    await device('b');
    await cloud.syncNow();
    mailbox.plant('TANDAV-9ZZZ', SyncBundle.encode(
      deviceId: 'TANDAV-9ZZZ',
      delta: SyncDelta(),
    ));
    await cloud.syncNow(); // fills B's second slot, delivering Morning to both
    await cloud.syncNow(); // …and drains B's file
    expect(await cloud.knownPeers(), hasLength(CloudSyncManager.maxPeers));
    expect(await cloud.pendingRowCount(), 0);

    // Both are gone: one phone replaced, and the other file was a leftover from
    // tools/fake-peer.html that somebody finally deleted.
    for (final id in [aId, 'TANDAV-9ZZZ']) {
      mailbox.files.remove(SyncMailbox.fileNameFor(id));
      mailbox.times.remove(SyncMailbox.fileNameFor(id));
    }

    await device('c');
    final cId = me();
    await seedBatch('Evening');
    await cloud.syncNow();

    await device('b');
    final stuck = await cloud.syncNow();
    expect(stuck.ok, isFalse);
    expect(stuck.message, contains(aId));
    expect(stuck.message, contains('TANDAV-9ZZZ'));
    expect(stuck.message, contains(cId));
    expect(stuck.message, contains('Forget the other device'));

    // The escape hatch, as the sync screen invokes it.
    expect(await cloud.forgetCloudPeer(), isNull);
    expect(await cloud.cloudPeerId, isNull);
    expect(await cloud.knownPeers(), isEmpty);

    final recovered = await cloud.syncNow();
    expect(recovered.ok, isTrue, reason: recovered.message);
    expect(recovered.peerDeviceId, cId);
    expect(await cloud.cloudPeerId, cId);

    // And real data actually flows from the replacement phone.
    final d = await open();
    expect(
      await d.query('batches', where: 'name = ?', whereArgs: ['Evening']),
      hasLength(1),
      reason: "the replacement phone's records never arrived",
    );

    // The other direction is the half that was silently broken. B had delivered
    // 'Morning' to both of the devices it knew, so its marks covered that row —
    // and C has never seen it. Forgetting the peers has to invalidate those
    // marks, or the studio's whole history stays on B forever while both
    // devices report a clean sync.
    await device('c');
    final backfilled = await cloud.syncNow();
    expect(backfilled.ok, isTrue, reason: backfilled.message);
    final onC = await open();
    expect(
      await onC.query('batches', where: 'name = ?', whereArgs: ['Morning']),
      hasLength(1),
      reason: 'forgetting the peers left the sent marks claiming the NEW device '
          'already had these rows, so they were never offered to it',
    );
  });

  test('disconnecting the account also forgets the peer', () async {
    // "Disconnect account" is the other way out of a wrong peer id, so it must
    // clear it too — otherwise reconnecting lands straight back in the same
    // stuck state and looks like the disconnect did nothing.
    await device('a');
    final aId = me();
    await seedBatch('Morning');
    await cloud.syncNow();

    await device('b');
    await cloud.syncNow();
    expect(await cloud.cloudPeerId, aId);
    expect(await cloud.cloudAccount, isNotNull);

    // B has now delivered everything it holds, so nothing is pending.
    await seedBatch('Evening');
    await cloud.syncNow();
    expect(await cloud.pendingRowCount(), 0);

    await cloud.disconnect();
    expect(await cloud.cloudPeerId, isNull);
    expect(await cloud.cloudAccount, isNull);

    // And the delivered marks went with it. They are a claim about the peer
    // that was just forgotten; the account may well be reconnected against a
    // different second device, which holds none of this.
    expect(await cloud.pendingRowCount(), greaterThan(0),
        reason: 'disconnect forgot the peer but kept claiming it had our rows');
  });

  test('forgetting the peer re-offers the whole database', () async {
    // The bug this pins, found on real hardware: `sent.<peerId>.<table>` does
    // not mean "uploaded", it means "that peer already holds this". Forgetting
    // the peer makes that false, so keeping the marks meant the replacement
    // device was adopted, both devices reported a clean sync, and the studio's
    // history was never offered to the new one. Nothing on screen said so.
    await device('a');
    await seedBatch('Morning');
    await seedStudent('Ravi');
    await cloud.syncNow();

    await device('b');
    await cloud.syncNow();
    expect(await cloud.pendingRowCount(), 2,
        reason: 'B holds these rows and re-offers them until A confirms — the '
            'echo is expected, and A discards it as unchanged');

    // A syncs again, now that B has left a file behind: that is the run where A
    // adopts B and its marks start meaning something. Before a peer exists there
    // is nobody to have delivered anything to, and pending correctly reports the
    // whole database.
    await device('a');
    await cloud.syncNow();
    expect(await cloud.pendingRowCount(), 0,
        reason: 'A delivered both rows to B, so its marks cover them');

    expect(await cloud.forgetCloudPeer(), isNull);
    expect(await cloud.cloudPeerId, isNull);
    expect(await cloud.pendingRowCount(), 2);

    // Which is the same state "Send everything again" produces — so a customer
    // who forgets a replaced device no longer has to know about that button.
    final full = await cloud.syncNow();
    expect(full.sent, 2, reason: full.message);
  });

  test('a mailbox that hangs still settles instead of wedging the UI', () async {
    await device('a', syncTimeout: const Duration(milliseconds: 50));
    await seedBatch('Morning');

    // The folder listing never comes back — a hung request rather than a
    // failing one, which is the case with no natural error to catch. It is also
    // the earliest thing a run does now that peers are settled before the
    // snapshot, so this stalls with nothing uploaded and nothing marked.
    mailbox.hangOnList = true;

    final seen = <CloudSyncStatus>[];
    final sub = cloud.status.listen(seen.add);
    final result = await cloud.syncNow();
    // `status` is a broadcast controller, so emits are delivered a turn later.
    // The terminal `failed` emit happens as syncNow returns, so without
    // yielding here it is still queued when the subscription is cancelled and
    // the assertion below reads the stale `connecting` phase instead.
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(result.ok, isFalse);
    expect(result.message, contains('timed out'));
    expect(mailbox.files, isEmpty, reason: 'the run never reached the upload');

    // This is the assertion that matters. device_sync_screen disables its Sync
    // button whenever the last emitted phase is a busy one, so without a
    // terminal emit the button stays dead and tapping it does nothing at all —
    // no alert, no error, no way out but force-closing the app.
    expect(seen.last.phase, CloudSyncPhase.failed);
    expect(seen.last.isBusy, isFalse);

    // The guard must also be released, or every later attempt just returns
    // "A sync is already running."
    expect(cloud.isRunning, isFalse);
  });

  test('pending counts report what is waiting to go out', () async {
    await device('a');
    expect(await cloud.pendingRowCount(), 0);
    await seedBatch('Morning');
    await seedStudent('Ravi');
    expect(await cloud.pendingRowCount(), 2);
    expect(await cloud.pendingByTable(), {'batches': 1, 'students': 1});
  });

  test('sync refuses to run when no account is connected', () async {
    await device('a');
    await seedBatch('Morning');
    mailbox.connected = false;
    final result = await cloud.syncNow();
    expect(result.ok, isFalse);
    expect(result.message, contains('Connect a sync account'));
    expect(mailbox.files, isEmpty);
  });

  test('Send everything again rebuilds a device that lost its data', () async {
    // The gap this closes: a mailbox file is a DELTA, not a backup. Once a
    // device has delivered everything, its file is empty — so a phone that was
    // wiped, replaced, or (on iPhone) had its PWA storage evicted by Safari
    // finds nothing in the account to restore from. There is no server, so
    // without this action the surviving phone's data can never be handed over.
    await device('a');
    final aId = me();
    final batchId = await seedBatch('Morning');
    await seedStudent('Ravi', batchId: batchId);
    await seedStudent('Meera', batchId: batchId);
    expect((await cloud.syncNow()).sent, 3);

    await device('b');
    final bId = me();
    expect((await cloud.syncNow()).applied, 3);

    // A syncs twice more: the first run adopts B and hands the three rows over,
    // the second finds nothing left to say. That second, empty upload is what
    // leaves the account holding no copy of anything.
    await device('a');
    await cloud.syncNow();
    await cloud.syncNow();
    final own = SyncMailbox.fileNameFor(aId);
    expect(
      SyncBundle.decode(mailbox.files[own]!).rowCount,
      0,
      reason: 'this empty file is exactly why the recovery action has to exist',
    );

    // B is wiped and comes back empty, with a new id and no file of its own.
    mailbox.files.remove(SyncMailbox.fileNameFor(bId));
    mailbox.times.remove(SyncMailbox.fileNameFor(bId));
    await device('b-wiped');
    final wipedId = me();
    final nothing = await cloud.syncNow();
    expect(nothing.ok, isTrue);
    expect(nothing.applied, 0);
    expect(await findStudent('Ravi'), isNull,
        reason: 'a delta-only mailbox cannot restore a blank device');

    // On the surviving phone: forget the id that will never return, then ask it
    // to hand over everything.
    await device('a');
    await cloud.forgetCloudPeer();
    final resend = await cloud.resendEverything();
    expect(resend.ok, isTrue, reason: resend.message);
    expect(resend.sent, 3);
    expect(SyncBundle.decode(mailbox.files[own]!).rowCount, 3);

    await device('b-wiped');
    final restored = await cloud.syncNow();
    expect(restored.ok, isTrue, reason: restored.message);
    expect(restored.applied, 3);
    expect(await findStudent('Ravi'), isNotNull);
    expect(await findStudent('Meera'), isNotNull);
    expect(wipedId, isNot(aId));

    // The rebuilt device is a full master again, foreign keys and all.
    final d = await open();
    final joined = await d.rawQuery('''
      SELECT b.name AS batch_name FROM students s
      JOIN batches b ON b.id = s.batch_id WHERE s.first_name = 'Meera'
    ''');
    expect(joined.single['batch_name'], 'Morning');
  });

  test('Send everything again is harmless when nothing is wrong', () async {
    // A customer who cannot tell whether they need this button must be able to
    // press it anyway. Re-offering rows the peer already has must not duplicate
    // them and — the case with real teeth — must not overwrite an edit the peer
    // made after we last sent it ours.
    await device('a');
    await seedStudent('Ravi');
    await cloud.syncNow();

    await device('b');
    await cloud.syncNow();
    final onB = await findStudent('Ravi');
    expect(onB, isNotNull);

    // B edits the student and has NOT uploaded that edit yet.
    await tick();
    await renameStudent(onB!['id'] as int, 'Ravi-Edited');

    // Meanwhile A re-offers its whole database, including its now-stale copy.
    await device('a');
    final resend = await cloud.resendEverything();
    expect(resend.ok, isTrue, reason: resend.message);
    expect(resend.sent, greaterThan(0));

    await device('b');
    final merged = await cloud.syncNow();
    expect(merged.ok, isTrue, reason: merged.message);
    expect(merged.applied, 0, reason: 'stale rows must not be applied');
    expect(merged.skipped, greaterThan(0));
    expect(await findStudent('Ravi-Edited'), isNotNull,
        reason: "the peer's newer edit was overwritten by a resend");
    expect(await findStudent('Ravi'), isNull);

    // And nothing was duplicated by arriving a second time.
    final d = await open();
    final all = await d.query('students');
    expect(all, hasLength(1));
  });

  test('a failed resend is remembered so the next sync carries it', () async {
    // The customer taps this precisely when something has gone wrong, which is
    // also when their internet is least likely to cooperate. The marks are
    // cleared in the database before the upload is attempted, so the request
    // survives the failure and they do not have to remember to come back.
    await device('a');
    await seedBatch('Morning');
    await seedStudent('Ravi');
    // A peer has to exist for "delivered" to mean anything: a sent mark is a
    // claim about one named device, so with nobody in the account the engine
    // correctly reports the whole database as still pending.
    mailbox.plant('TANDAV-9ZZZ', SyncBundle.encode(
      deviceId: 'TANDAV-9ZZZ',
      delta: SyncDelta(),
    ));
    expect((await cloud.syncNow()).sent, 2);
    expect(await cloud.pendingRowCount(), 0);

    mailbox.connected = false;
    final offline = await cloud.resendEverything();
    expect(offline.ok, isFalse);
    expect(offline.message, contains('remembered'));
    expect(await cloud.pendingRowCount(), 2,
        reason: 'the whole dataset must be queued again even though the sync '
            'itself could not run');

    mailbox.connected = true;
    final later = await cloud.syncNow();
    expect(later.ok, isTrue, reason: later.message);
    expect(later.sent, 2);
  });
}
