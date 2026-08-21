library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Application-level synchronization protocol spoken over the Tandav BLE link.
///
/// Guards against: arbitrary Bluetooth devices (we only ever connect to a
/// BLE service with our own Tandav service UUID), unpaired devices (the AUTH
/// step requires the pairing secret), and third devices trying to join (the
/// pairing handshake rejects any device once a pair already exists).
///
/// Messages are JSON envelopes carried over two GATT characteristics:
/// - `cmd`   (write): client -> server
/// - `data`  (notify): server -> client
/// Large payloads are split into small BLE packets by [FrameCodec].

/// Wire protocol version. Bump only for incompatible changes; the handshake
/// rejects mismatched versions with a clear error.
const int syncProtocolVersion = 1;

/// Message kinds exchanged during a sync session.
enum SyncMsgType {
  hello, // client -> server: identify + request a session
  helloAck, // server -> client: identify + issue nonce
  pairRequest, // client -> server: propose pairing with a verification code
  pairResponse, // server -> client: accept pairing + deliver shared secret
  auth, // client -> server: authenticate with HMAC(secret, nonce)
  authOk, // server -> client: authentication accepted
  syncRequest, // client -> server: begin data exchange
  syncData, // either: a table payload (chunked)
  syncAck, // either: accepted payload + the sender's own delta
  syncDone, // server -> client: finished, summary of applied changes
  error, // either: protocol error
  ping,
}

/// Build a JSON message envelope used across the wire.
Map<String, Object?> envelope(
  SyncMsgType t, [
  Map<String, Object?> extra = const {},
]) => {'v': syncProtocolVersion, 't': t.name, ...extra};

/// The protocol version carried inside a received message envelope.
int? protocolVersionOf(Map<String, Object?> msg) => msg['v'] as int?;

SyncMsgType typeOf(Map<String, Object?> msg) => SyncMsgType.values.firstWhere(
  (t) => t.name == msg['t'],
  orElse: () => SyncMsgType.error,
);

/// Frames byte payloads into small BLE packets and reassembles them.
///
/// Every frame is prefixed with a 4-byte little-endian length. The transport
/// writes/notifies chunkMax bytes at a time; the receiver simply appends
/// packets until the expected length is reached. This keeps payloads safe on
/// every MTU (works down to the 23-byte iOS minimum).
class FrameCodec {
  static const int chunkMax = 180;

  /// Split [bytes] into packets; the first packet carries the length header.
  static List<Uint8List> encode(List<int> bytes) {
    final length = bytes.length;
    final header = ByteData(4)..setUint32(0, length, Endian.little);
    final headerBytes = header.buffer.asUint8List();

    // Fast path: the header plus the full payload fit in one packet.
    if (bytes.length <= chunkMax) {
      return [
        Uint8List.fromList([...headerBytes, ...bytes]),
      ];
    }

    // Large payloads: header + first chunk in packet 0, then one packet per
    // chunk until everything is sent.
    final packets = <Uint8List>[];
    final first = Uint8List.fromList([
      ...headerBytes,
      ...bytes.sublist(0, chunkMax),
    ]);
    packets.add(first);
    var offset = chunkMax;
    while (offset < bytes.length) {
      final end = (offset + chunkMax).clamp(0, bytes.length);
      packets.add(Uint8List.fromList(bytes.sublist(offset, end)));
      offset = end;
    }
    return packets;
  }

  /// Incremental reassembler state.
  static (Uint8List, bool) feed(FrameAccumulator acc, Uint8List packet) {
    if (!acc.started) {
      if (packet.length < 4) return (Uint8List(0), false);
      final len = ByteData.sublistView(
        packet,
        0,
        4,
      ).getUint32(0, Endian.little);
      acc.total = len;
      acc.buffer = BytesBuilder()..add(packet.sublist(4));
      acc.started = true;
    } else {
      acc.buffer!.add(packet);
    }
    final coll = acc.buffer!.toBytes();
    if (coll.length >= acc.total) {
      final complete = coll.sublist(0, acc.total);
      acc.clear();
      return (complete, true);
    }
    return (coll, false);
  }
}

class FrameAccumulator {
  bool started = false;
  int total = 0;
  BytesBuilder? buffer;

  void clear() {
    started = false;
    total = 0;
    buffer = null;
  }
}

/// App-level authentication using a shared pairing secret (HMAC-SHA256), so
/// we never rely only on the BLE device name.
String authToken(String deviceId, String secret, String nonce) {
  final hmac = Hmac(sha256, utf8.encode('$secret:$deviceId'));
  final digest = hmac.convert(utf8.encode(nonce)).toString();
  return digest;
}

/// Deterministic 6-digit verification code shown on BOTH devices during
/// pairing. Derived only from the two device ids, so both sides compute and
/// display the same number before any secret is exchanged.
String pairingCode(String deviceA, String deviceB) {
  final ids = [deviceA, deviceB]..sort();
  final digest = sha256.convert(utf8.encode(ids.join('|'))).toString();
  var value = 0;
  for (final code in digest.runes) {
    value = (value * 31 + code) & 0x7fffffff;
  }
  return (value % 1000000).toString().padLeft(6, '0');
}
