/// A remote "mailbox" that two Tandav devices can drop files into.
///
/// This is the *only* thing the cloud sync path needs from the outside world:
/// a place where each device can write one small file and read the other
/// device's file. Nothing here knows about Google Drive — the Drive
/// implementation lives in `drive_mailbox.dart`, and tests use an in-memory
/// fake. That keeps the merge engine, the orchestration and the tests all
/// runnable on a laptop with no network and no Google account.
///
/// Why a mailbox instead of a live connection: the two masters are in
/// different places and are almost never online at the same moment. A mailbox
/// is *store-and-forward* — device A writes whenever it happens to have
/// internet, device B picks it up whenever it next opens the app. Neither
/// device ever waits for the other, and there is no server to run.
library;

/// One file sitting in the mailbox.
class MailboxEntry {
  const MailboxEntry({
    required this.id,
    required this.name,
    this.modifiedAt,
    this.sizeBytes,
  });

  /// Opaque provider id (a Drive file id, a path, a map key…). Used to read
  /// and to overwrite the file in place so we never accumulate duplicates.
  final String id;

  /// File name, e.g. `tandav-TANDAV-4F2A.json`.
  final String name;

  /// Server-side last-modified time, when the provider reports one. Only used
  /// for display and for ordering; never for conflict resolution — that is
  /// decided per row by the merge engine, not per file.
  final DateTime? modifiedAt;

  final int? sizeBytes;

  /// The `TANDAV-XXXX` id encoded in [name], or null when the name does not
  /// follow the Tandav convention (a stray file someone dropped in the
  /// folder). Unknown names are ignored rather than treated as an error.
  String? get deviceId => SyncMailbox.deviceIdFromFileName(name);
}

/// Raised for any mailbox failure that the user can act on. The message is
/// written to be shown directly in the UI.
class MailboxException implements Exception {
  MailboxException(this.message, {this.isAuthFailure = false});

  final String message;

  /// True when the fix is "sign in again" rather than "try again later".
  final bool isAuthFailure;

  @override
  String toString() => message;
}

/// Store-and-forward file store shared by the two master devices.
///
/// Implementations must be safe to call repeatedly: [writeOwn] overwrites the
/// caller's single file rather than appending a new one, so the mailbox never
/// grows beyond one file per device.
abstract class SyncMailbox {
  /// Prefix of every Tandav bundle file name.
  static const filePrefix = 'tandav-';

  /// Suffix of every Tandav bundle file name.
  static const fileSuffix = '.json';

  /// File name this device writes to. One fixed name per device means the
  /// mailbox holds one file per device that has ever synced — three at most,
  /// which is [CloudSyncManager.maxDevices].
  static String fileNameFor(String deviceId) =>
      '$filePrefix$deviceId$fileSuffix';

  /// Inverse of [fileNameFor]; null when [name] is not a Tandav bundle.
  static String? deviceIdFromFileName(String name) {
    if (!name.startsWith(filePrefix) || !name.endsWith(fileSuffix)) return null;
    final id = name.substring(
      filePrefix.length,
      name.length - fileSuffix.length,
    );
    return id.isEmpty ? null : id;
  }

  /// Human-readable name of the account/location the mailbox points at, shown
  /// on the sync screen (e.g. the signed-in Google address). Null until
  /// connected.
  String? get accountLabel;

  /// True once the mailbox is usable without further user interaction.
  Future<bool> isConnected();

  /// Interactive connect (sign-in / permission prompt). Safe to call when
  /// already connected. Throws [MailboxException] on failure.
  Future<void> connect();

  /// Restore a previous connection without showing any UI. Returns false when
  /// the user must connect interactively again. Called on app start so a
  /// returning user never sees a prompt.
  Future<bool> connectSilently();

  /// Forget the connection on this device. Never deletes remote data — the
  /// peer may still need to read our bundle.
  Future<void> disconnect();

  /// Every Tandav bundle currently in the mailbox, including our own.
  Future<List<MailboxEntry>> list();

  /// Full contents of [entry] as UTF-8 text.
  Future<String> read(MailboxEntry entry);

  /// Write (or overwrite) this device's own bundle.
  Future<void> writeOwn(String deviceId, String contents);

  /// Remove a file. Used only when the user explicitly resets sync.
  Future<void> delete(MailboxEntry entry);

  /// Bundles written by devices other than [ownDeviceId], newest first.
  /// Files that do not follow the Tandav naming convention are skipped.
  Future<List<MailboxEntry>> peerEntries(String ownDeviceId) async {
    final all = await list();
    final peers = all
        .where((e) => e.deviceId != null && e.deviceId != ownDeviceId)
        .toList();
    peers.sort((a, b) {
      final at = a.modifiedAt;
      final bt = b.modifiedAt;
      if (at == null && bt == null) return a.name.compareTo(b.name);
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return peers;
  }
}
