/// One logical Bluetooth LE link with both roles, so either device can
/// initiate the sync session.
///
/// - Peripheral role (advertises + hosts the Tandav GATT server):
///   `ble_peripheral`. Exposes the Tandav service with a `cmd` (write) and a
///   `data` (notify) characteristic. The device in this role is *discoverable*:
///   other Tandav devices find it while scanning.
/// - Central role (scans + connects): `flutter_blue_plus`, a GATT client that
///   scans for the Tandav service, subscribes to `data` and writes frames to
///   `cmd`.
///
/// Roles are temporary per session. Both devices are always advertising their
/// Tandav identity while a session is open, so there is always a discoverable
/// Tandav device whenever another Tandav device is scanning — it is never the
/// case that both phones are only scanning and waiting for each other. Once a
/// peer is located, `SyncManager` decides (deterministically from the device
/// ids) which phone takes the central role and which keeps the peripheral.
///
/// Every BLE/platform call is wrapped so unexpected failures surface as a
/// friendly message instead of crashing the app.
library;

import 'dart:async';
import 'dart:io';

import 'package:ble_peripheral/ble_peripheral.dart' as bp;
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:permission_handler/permission_handler.dart' as ph;

import 'protocol.dart';

/// Our own Tandav BLE service and characteristic UUIDs. Scan/connection is
/// filtered to these so we only ever discover and talk to other Tandav
/// devices, never arbitrary Bluetooth hardware. These constants are shared
/// verbatim by every Tandav client (Android and iOS).
const String kTandavServiceUuid = '6d61726b-0001-4f64-4144-530000000001';
const String kTandavCmdCharUuid = '6d61726b-0001-4f64-4144-530000000002';
const String kTandavDataCharUuid = '6d61726b-0001-4f64-4144-530000000003';
const String kTandavAdvertNamePrefix = 'Tandav';

final RegExp _tandavIdPattern = RegExp(r'TANDAV-[2-9A-HJKMNP-Z]{4}');

/// A detected peer running the Tandav app.
class BlePeer {
  /// Bluetooth address (central-side identifier).
  final String id;

  /// The peer's TANDAV-XXXX device id (parsed from its advertised name).
  final String deviceId;

  /// Original advertised name (e.g. "Tandav TANDAV-A7F3").
  final String name;

  /// The peer's platform as reported by the BLE stack ("Android", "iOS", …).
  final String platform;

  /// Latest signal strength observed, in dBm.
  final int rssi;

  BlePeer(this.id, this.deviceId, this.name, this.platform, this.rssi);

  bool get isNearby => rssi == 0 || rssi >= -75;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlePeer && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => name;
}

/// Result of a BLE operation. When [ok] is false, [message] is a
/// user-friendly explanation (never an exception).
class BleOutcome {
  final bool ok;
  final String message;

  const BleOutcome.ok({this.message = ''}) : ok = true;
  const BleOutcome.fail(this.message) : ok = false;

  factory BleOutcome.failIf(String? message) =>
      message == null ? const BleOutcome.ok() : BleOutcome.fail(message);
}

class BlesLink {
  final _frames = StreamController<Uint8List>.broadcast();
  final _log = StreamController<String>.broadcast(sync: true);
  final FrameAccumulator _acc = FrameAccumulator();

  bool _peripheralReady = false;
  bool _advertising = false;

  fbp.BluetoothDevice? _device;
  fbp.BluetoothCharacteristic? _cmd;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<fbp.BluetoothConnectionState>? _connSub;

  StreamSubscription<List<fbp.ScanResult>>? _scanSub;

  String _selfDeviceId = '';

  /// Complete reassembled application frames, one at a time.
  Stream<Uint8List> get frames => _frames.stream;

  /// Human-readable transport events ("BLE: …") for the "Device & Sync"
  /// screen and for diagnosing advertising/scanning problems.
  Stream<String> get log => _log.stream;

  void _trace(String msg) {
    if (!_log.isClosed) _log.add(msg);
  }

  // ---------------------------------------------------------------- shared

  /// Grant every permission this app needs for the current Android version
  /// and make sure Bluetooth is switched on. Returns a user-friendly error
  /// message when something is missing, or null when everything is ready.
  Future<String?> ensureBluetoothReady() async {
    final err = await ensurePermissions();
    if (err != null) return err;
    return ensureAdapterOn();
  }

  /// Request the runtime Bluetooth permissions required by the current
  /// Android version:
  /// - Android 12+ (API 31+): BLUETOOTH_SCAN, BLUETOOTH_CONNECT and
  ///   BLUETOOTH_ADVERTISE (all three — advertising fails without ADVERTISE).
  /// - Older Android: location is required to scan for BLE devices; the
  ///   other Bluetooth permissions are install-time there.
  Future<String?> ensurePermissions() async {
    if (!kIsWeb && !Platform.isAndroid) return null;
    final permissions = <ph.Permission>[];
    final sdk = await _androidSdkInt();
    if (sdk != null && sdk >= 31) {
      permissions.addAll([
        ph.Permission.bluetoothScan,
        ph.Permission.bluetoothConnect,
        ph.Permission.bluetoothAdvertise,
      ]);
    } else {
      permissions.add(ph.Permission.locationWhenInUse);
    }
    for (final p in permissions) {
      final s = await p.request();
      if (!s.isGranted && !s.isLimited) {
        return 'Bluetooth permission is required to find another Tandav device.';
      }
    }
    return null;
  }

  Future<int?> _androidSdkInt() async {
    if (Platform.isAndroid) {
      return int.tryParse(Platform.version.split(' ').first);
    }
    return null;
  }

  /// Check that the Bluetooth adapter exists and is enabled.
  Future<String?> ensureAdapterOn() async {
    try {
      final supported = await fbp.FlutterBluePlus.isSupported;
      if (!supported) {
        return 'Bluetooth is not available on this phone.';
      }
    } catch (_) {}
    try {
      final state = await fbp.FlutterBluePlus.adapterState.firstWhere(
        (s) => s != fbp.BluetoothAdapterState.turningOn,
        orElse: () => fbp.BluetoothAdapterState.off,
      );
      if (state != fbp.BluetoothAdapterState.on) {
        return 'Bluetooth is turned off. Turn it on and try again.';
      }
    } catch (_) {
      return 'Bluetooth is turned off. Turn it on and try again.';
    }
    return null;
  }

  bool get isAdvertising => _advertising;

  void _onPacket(Uint8List packet) {
    final (frame, done) = FrameCodec.feed(_acc, packet);
    if (done && !_frames.isClosed) _frames.add(frame);
  }

  /// Outbound: split into BLE packets and hand them to the current role.
  Future<void> sendFrame(List<int> payload) async {
    try {
      for (final packet in FrameCodec.encode(payload)) {
        if (!await _sendPacket(packet)) return;
      }
    } catch (e) {
      _trace('BLE: Failed to send data: $e');
    }
  }

  Future<bool> _sendPacket(Uint8List packet) async {
    if (_cmd != null) {
      // central role: push to the peer's GATT server
      await _cmd!.write(packet, withoutResponse: true);
      return true;
    }
    if (_peripheralReady && _advertising) {
      // peripheral role: broadcast to subscribed centrals
      await bp.BlePeripheral.updateCharacteristic(
        characteristicId: kTandavDataCharUuid,
        value: packet,
      );
      return true;
    }
    return false;
  }

  // ----------------------------------------------------------- peripheral

  /// Start advertising the Tandav identity using [deviceName]
  /// (e.g. "Tandav TANDAV-A7F3"). Failure to advertise is reported through
  /// [BleOutcome] and logged; the app never crashes.
  Future<BleOutcome> startAdvertising(String deviceName) async {
    String? parseId(String n) => _tandavIdPattern.firstMatch(n)?.group(0);
    _selfDeviceId = parseId(deviceName) ?? '';
    _trace('BLE: Starting advertising');
    if (_selfDeviceId.isNotEmpty) {
      _trace('BLE: Advertising as $_selfDeviceId');
    }
    try {
      final outcome = await _ensurePeripheral();
      if (!outcome.ok) return outcome;
      await bp.BlePeripheral.startAdvertising(
        services: [kTandavServiceUuid],
        localName: deviceName,
      );
      _advertising = true;
      _trace('BLE: Advertising started successfully');
      return const BleOutcome.ok();
    } catch (e) {
      _advertising = false;
      _trace('BLE: Advertising failed');
      _trace('BLE: reason = $e');
      return BleOutcome.fail(
        'Unable to start Bluetooth advertising on this phone.',
      );
    }
  }

  Future<void> stopAdvertising() async {
    _advertising = false;
    try {
      await bp.BlePeripheral.stopAdvertising();
    } catch (_) {}
    _trace('BLE: Advertising stopped');
  }

  /// Arm the GATT server (once) and register every callback. The plugin on
  /// Android throws UnsupportedOperationException when Bluetooth/LE
  /// advertising is unavailable, which we surface as a friendly message.
  Future<BleOutcome> _ensurePeripheral() async {
    if (_peripheralReady) return const BleOutcome.ok();
    try {
      final supported = await bp.BlePeripheral.isSupported();
      if (!supported) {
        return const BleOutcome.fail(
          'Unable to start Bluetooth advertising on this phone.',
        );
      }
    } catch (_) {}
    try {
      await bp.BlePeripheral.initialize();
    } catch (e) {
      _trace('BLE: Peripheral not available: $e');
      return BleOutcome.fail(
        'Unable to start Bluetooth advertising on this phone.',
      );
    }
    bp.BlePeripheral.setWriteRequestCallback((
      deviceId,
      characteristicId,
      offset,
      value,
    ) {
      if (value != null && value.isNotEmpty) _onPacket(value);
      return bp.WriteRequestResult(offset: offset, status: 0);
    });
    bp.BlePeripheral.setReadRequestCallback(
      (deviceId, characteristicId, offset, value) => bp.ReadRequestResult(
        value: value ?? Uint8List(0),
        offset: offset,
        status: 0,
      ),
    );
    bp.BlePeripheral.setAdvertisingStatusUpdateCallback((advertising, error) {
      if (advertising) {
        _trace('BLE: Advertising started successfully');
      } else if (error != null) {
        _advertising = false;
        _trace('BLE: Advertising failed');
        _trace('BLE: reason = $error');
      }
    });
    if (!kIsWeb && Platform.isAndroid) {
      bp.BlePeripheral.setConnectionStateChangeCallback((deviceId, connected) {
        if (connected) {
          _trace('BLE: Peer connected to this device');
        } else {
          _trace('BLE: Peer disconnected');
        }
      });
    }
    try {
      await bp.BlePeripheral.addService(
        bp.BleService(
          uuid: kTandavServiceUuid,
          primary: true,
          characteristics: [
            bp.BleCharacteristic(
              uuid: kTandavCmdCharUuid,
              properties: [
                bp.CharacteristicProperties.write.index,
                bp.CharacteristicProperties.writeWithoutResponse.index,
              ],
              permissions: [bp.AttributePermissions.writeable.index],
              value: null,
            ),
            bp.BleCharacteristic(
              uuid: kTandavDataCharUuid,
              properties: [
                bp.CharacteristicProperties.read.index,
                bp.CharacteristicProperties.notify.index,
              ],
              permissions: [bp.AttributePermissions.readable.index],
              value: null,
            ),
          ],
        ),
      );
    } catch (e) {
      _trace('BLE: Service setup failed: $e');
      return BleOutcome.fail(
        'Unable to start Bluetooth advertising on this phone.',
      );
    }
    _peripheralReady = true;
    return const BleOutcome.ok();
  }

  // -------------------------------------------------------------- central

  /// Scan for Tandav devices advertising our service. [onPeers] is invoked
  /// with the current list of discovered Tandav peers whenever it changes.
  /// Returns null (no error) or a user-friendly error message.
  Future<String?> startDiscovering(
    void Function(List<BlePeer> peers) onPeers,
  ) async {
    await stopDiscovering();
    final tracedPeers = <String>{};
    try {
      _trace('BLE: Scan started');
      _scanSub = fbp.FlutterBluePlus.scanResults.listen((results) {
        final peers = <BlePeer>[];
        for (final r in results) {
          final name = r.advertisementData.advName;
          final m = _tandavIdPattern.firstMatch(name);
          if (m == null) continue;
          final deviceId = m.group(0)!;
          if (deviceId == _selfDeviceId) continue;
          peers.add(
            BlePeer(
              r.device.remoteId.str,
              deviceId,
              name,
              r.device.platformName.isEmpty ? 'Android' : r.device.platformName,
              r.rssi,
            ),
          );
        }
        // newest result per peer wins; sort by name for a stable list
        final byId = <String, BlePeer>{};
        for (final p in peers) {
          byId[p.id] = p;
          if (tracedPeers.add(p.deviceId)) {
            _trace('BLE: Discovered ${p.name}');
          }
        }
        onPeers(byId.values.toList()..sort((a, b) => a.name.compareTo(b.name)));
      });
      await fbp.FlutterBluePlus.startScan(
        withServices: [fbp.Guid(kTandavServiceUuid)],
        timeout: const Duration(minutes: 3),
        androidCheckLocationServices: false,
      );
      return null;
    } catch (e) {
      _trace('BLE: Scan failed: $e');
      await stopDiscovering();
      return 'Could not start scanning for Tandav devices on this phone.';
    }
  }

  Future<void> stopDiscovering() async {
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await fbp.FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  /// Connect to [peer] as the central, discover the Tandav service and
  /// subscribe to `data`. Returns null on success or a friendly error.
  Future<String?> connectCentral(BlePeer peer) async {
    await disconnectCentral();
    final device = fbp.BluetoothDevice.fromId(peer.id);
    try {
      _trace('BLE: Connecting to ${peer.deviceId}');
      await device.connect(
        license: fbp.License.nonprofit,
        timeout: const Duration(seconds: 20),
      );
      await device.connectionState.firstWhere(
        (s) => s == fbp.BluetoothConnectionState.connected,
        orElse: () => fbp.BluetoothConnectionState.disconnected,
      );
    } catch (e) {
      _trace('BLE: Connect failed: $e');
      try {
        await device.disconnect();
      } catch (_) {}
      return 'Could not connect to ${peer.deviceId}.';
    }
    try {
      final services = await device.discoverServices();
      fbp.BluetoothService? svc;
      for (final s in services) {
        if (s.uuid.str == kTandavServiceUuid) {
          svc = s;
          break;
        }
      }
      if (svc == null) {
        _trace('BLE: Tandav service not found on ${peer.deviceId}');
        await device.disconnect();
        return '${peer.deviceId} is not running the Tandav app.';
      }
      fbp.BluetoothCharacteristic? cmd;
      fbp.BluetoothCharacteristic? data;
      for (final c in svc.characteristics) {
        if (c.uuid.str == kTandavCmdCharUuid) cmd = c;
        if (c.uuid.str == kTandavDataCharUuid) data = c;
      }
      if (cmd == null || data == null) {
        _trace('BLE: Tandav characteristics not found on ${peer.deviceId}');
        await device.disconnect();
        return '${peer.deviceId} is running an incompatible Tandav version.';
      }
      await data.setNotifyValue(true);
      _notifySub = data.onValueReceived.listen(
        (bytes) => _onPacket(Uint8List.fromList(bytes)),
      );
      _device = device;
      _cmd = cmd;
      _connSub = device.connectionState.listen((s) {
        if (s != fbp.BluetoothConnectionState.connected) {
          _trace('BLE: Connection to ${peer.deviceId} lost');
        }
      });
      _trace('BLE: Connected to ${peer.deviceId}');
      return null;
    } catch (e) {
      _trace('BLE: Service discovery failed: $e');
      try {
        await device.disconnect();
      } catch (_) {}
      return 'Could not read ${peer.deviceId} — the BLE service is unavailable.';
    }
  }

  Future<void> disconnectCentral() async {
    await _connSub?.cancel();
    _connSub = null;
    await _notifySub?.cancel();
    _notifySub = null;
    _cmd = null;
    final device = _device;
    _device = null;
    if (device != null) {
      try {
        if (device.isConnected) await device.disconnect();
      } catch (_) {}
    }
  }

  /// Tear down every active link. Advertising is managed separately by the
  /// session so a peer can still find us while we wait.
  Future<void> disconnectAll() async {
    await stopDiscovering();
    await disconnectCentral();
  }

  bool get isConnected => _device != null;

  void dispose() {
    _scanSub?.cancel();
    _notifySub?.cancel();
    _connSub?.cancel();
    _frames.close();
    _log.close();
    _acc.clear();
  }
}
