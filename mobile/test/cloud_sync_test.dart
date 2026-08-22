import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  /// and rebuild the sync stack around it. Both devices share one [mailbox],
  /// exactly as two phones share one Drive account.
  Future<void> device(String name) async {
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
      engine: SyncEngine(db, state),
      mailbox: mailbox,
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

  test('a third device is refused instead of merged', () async {
    await device('a');
    final aId = me();
    await seedBatch('Morning');
    await cloud.syncNow();

    await device('b');
    await cloud.syncNow();
    expect(await cloud.cloudPeerId, aId);

    // Someone installs Tandav on a third phone and signs into the same
    // account. Two masters is the documented limit.
    mailbox.plant('TANDAV-9ZZZ', SyncBundle.encode(
      deviceId: 'TANDAV-9ZZZ',
      delta: SyncDelta(),
    ));

    // The known pair still syncs fine — the stranger is simply not chosen.
    final ok = await cloud.syncNow();
    expect(ok.ok, isTrue);
    expect(ok.peerDeviceId, aId);

    // A brand-new device cannot tell which of the two is its partner, so it
    // refuses rather than guessing.
    await device('c');
    final fresh = await cloud.syncNow();
    expect(fresh.ok, isFalse);
    expect(fresh.message, contains('two Tandav devices'));
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
}
