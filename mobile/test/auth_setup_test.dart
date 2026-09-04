import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tandav_mobile/core/services.dart';
import 'package:tandav_mobile/database/db_helpers.dart';
import 'package:tandav_mobile/database/tandav_database.dart';

/// First-run setup and password recovery.
///
/// The stakes here are unusual: there is no server, so a bug that loses the
/// recovery code, or a check that lets `admin123` survive setup, is the
/// difference between a studio getting back into its own data and not. These
/// tests exist to pin the parts that have no second line of defence.
void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late int dbSeq;

  /// A brand-new database, seeded exactly as a first launch would be.
  Future<TandavApi> freshApi() async {
    final db = TandavDatabase.instance;
    await db.close();
    final path = p.join(tempDir.path, 'auth_${dbSeq++}.db');
    if (await File(path).exists()) await File(path).delete();
    db.configureForTest(factory: databaseFactoryFfi, overridePath: path);
    final api = TandavApi(database: db);
    await db.open();
    return api;
  }

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tandav_auth_');
    dbSeq = 0;
  });

  tearDownAll(() async {
    await TandavDatabase.instance.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a fresh install reports itself as still on factory credentials',
      () async {
    final api = await freshApi();
    expect(await api.auth.isFactoryDefault(), isTrue,
        reason: 'this is what puts the signup screen in front of everything');
    expect(await api.auth.recoveryCode(), isNull);
  });

  test('setup rewrites the factory account in place and issues a code',
      () async {
    final api = await freshApi();
    final d = await TandavDatabase.instance.open();
    final idBefore = (await d.query('users', columns: ['id'])).single['id'];

    final code = await api.auth.completeSetup(
      username: 'meera',
      fullName: 'Meera Raghavan',
      password: 'dance2026',
    );

    expect(code, matches(r'^TNDV-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$'));
    expect(await api.auth.isFactoryDefault(), isFalse);
    expect(await api.auth.recoveryCode(), code);

    // One row, same id. A delete-then-insert would have raced the seeding in
    // _seedAdminIfNeeded and could have shifted the id under a saved session.
    final rows = await d.query('users');
    expect(rows, hasLength(1));
    expect(rows.single['id'], idBefore);
    expect(rows.single['username'], 'meera');
    expect(rows.single['full_name'], 'Meera Raghavan');

    expect(await api.auth.verifyLogin('meera', 'dance2026'), isNotNull);
    expect(await api.auth.verifyLogin('admin', 'admin123'), isNull,
        reason: 'the credentials every APK ships with must stop working');
  });

  test('setup refuses the password that ships in every copy of the app',
      () async {
    final api = await freshApi();
    await expectLater(
      api.auth.completeSetup(
          username: 'admin', fullName: 'Studio', password: 'admin123'),
      throwsA(isA<RepoException>()),
    );
    // Still flagged as un-set-up, so the screen comes back rather than leaving
    // the studio on a password that is identical in every install.
    expect(await api.auth.isFactoryDefault(), isTrue);
  });

  test('setup cannot be run a second time', () async {
    final api = await freshApi();
    await api.auth.completeSetup(
        username: 'meera', fullName: 'Meera', password: 'dance2026');
    await expectLater(
      api.auth.completeSetup(
          username: 'someone', fullName: 'Else', password: 'takeover'),
      throwsA(isA<RepoException>()),
    );
    expect(await api.auth.verifyLogin('meera', 'dance2026'), isNotNull);
  });

  test('the recovery code resets the password however sloppily it is typed',
      () async {
    final api = await freshApi();
    final code = await api.auth.completeSetup(
        username: 'meera', fullName: 'Meera', password: 'first-pass');

    // Lower case, spaces instead of dashes — the state a code comes back in
    // when it is read off a piece of paper.
    final sloppy = code.toLowerCase().replaceAll('-', ' ');
    final account = await api.auth.resetWithRecoveryCode(sloppy, 'second-pass');

    expect(account.username, 'meera');
    expect(await api.auth.verifyLogin('meera', 'second-pass'), isNotNull);
    expect(await api.auth.verifyLogin('meera', 'first-pass'), isNull);

    // Not rotated: the note they wrote months ago still works, which is the
    // whole reason they got back in this time.
    expect(await api.auth.recoveryCode(), code);
  });

  test('a wrong recovery code changes nothing at all', () async {
    final api = await freshApi();
    await api.auth.completeSetup(
        username: 'meera', fullName: 'Meera', password: 'keepme');

    await expectLater(
      api.auth.resetWithRecoveryCode('TNDV-0000-0000', 'takeover'),
      throwsA(isA<RepoException>()),
    );
    expect(await api.auth.verifyLogin('meera', 'keepme'), isNotNull);
    expect(await api.auth.verifyLogin('meera', 'takeover'), isNull);
  });

  test('an install that never had a recovery code can be issued one', () async {
    final api = await freshApi();
    // Stands in for a copy of the app whose password was changed before
    // recovery codes existed: a real password, but nothing in app_settings.
    await api.auth.changePassword('admin', 'admin123', 'oldschool');
    expect(await api.auth.isFactoryDefault(), isFalse);
    expect(await api.auth.recoveryCode(), isNull);

    final code = await api.auth.ensureRecoveryCode();
    expect(code, matches(r'^TNDV-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$'));

    // Idempotent. Re-rolling would silently void a code already written down.
    expect(await api.auth.ensureRecoveryCode(), code);
    expect(await api.auth.recoveryCode(), code);
  });

  test('changing a password rejects the factory one', () async {
    final api = await freshApi();
    await api.auth.completeSetup(
        username: 'meera', fullName: 'Meera', password: 'dance2026');
    await expectLater(
      api.auth.changePassword('meera', 'dance2026', 'admin123'),
      throwsA(isA<RepoException>()),
    );
    expect(await api.auth.verifyLogin('meera', 'dance2026'), isNotNull);
  });

  test('recovery codes compare equal across case, spaces, dashes and prefix',
      () {
    const canonical = 'TNDV-4F7K-9QX2';
    const target = '4F7K9QX2';
    for (final variant in [
      'TNDV-4F7K-9QX2',
      'tndv-4f7k-9qx2',
      'TNDV 4F7K 9QX2',
      'tndv4f7k9qx2',
      '4F7K-9QX2',
      '  4f7k 9qx2  ',
    ]) {
      expect(TandavDatabase.normalizeRecoveryCode(variant), target,
          reason: 'variant: "$variant"');
    }
    expect(TandavDatabase.normalizeRecoveryCode(canonical), target);

    // A code that is merely similar must not match.
    expect(TandavDatabase.normalizeRecoveryCode('TNDV-4F7K-9QX3'),
        isNot(target));
  });
}
