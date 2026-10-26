import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/util/tap_to_share/peer_tap_matcher.dart';

/// Default UDP port for Tap-to-Share peer announcements and NTP clock sync (`53318`, adjacent to LocalSend `53317`).
const int kTapToShareDefaultUdpPort = 53318;

/// Default LocalSend multicast group.
const String kTapToShareMulticastGroup = '224.0.0.167';

/// Received peer tap announcement alongside the sender's network address and local receive timestamp.
class ReceivedUdpTapPacket {
  final PeerTapAnnouncement announcement;
  final InternetAddress senderAddress;
  final int senderPort;
  final int receivedAtLocalUs;

  const ReceivedUdpTapPacket({
    required this.announcement,
    required this.senderAddress,
    required this.senderPort,
    required this.receivedAtLocalUs,
  });
}

/// Coordinates lightweight UDP packets (`tap_announce`, `clock_ping`, `clock_pong`) across LAN peers (`Spec 011`).
///
/// Complies strictly with rule `R2.5`: operates in Dart without modifying LocalSend's Rust HTTP server.
class TapUdpCoordinator {
  final String localFingerprint;
  final PeerClockEstimator clockEstimator;
  final int listenPort;
  final int Function() _nowUs;

  RawDatagramSocket? _socket;
  final StreamController<ReceivedUdpTapPacket> _announcementController = StreamController<ReceivedUdpTapPacket>.broadcast();
  final StreamController<PeerClockEstimate> _clockSyncController = StreamController<PeerClockEstimate>.broadcast();

  TapUdpCoordinator({
    required String localFingerprint,
    PeerClockEstimator? clockEstimator,
    this.listenPort = kTapToShareDefaultUdpPort,
    int Function()? nowUs,
  }) : localFingerprint = localFingerprint.trim().toUpperCase(),
       clockEstimator = clockEstimator ?? PeerClockEstimator(),
       _nowUs = nowUs ?? (() => DateTime.now().microsecondsSinceEpoch);

  bool get isRunning => _socket != null;

  /// Bound local UDP port (useful when `listenPort == 0` in ephemeral socket tests).
  int get boundPort => _socket?.port ?? listenPort;

  Stream<ReceivedUdpTapPacket> get announcementStream => _announcementController.stream;
  Stream<PeerClockEstimate> get clockSyncStream => _clockSyncController.stream;

  /// Starts the UDP listener socket and joins the multicast/broadcast group when supported.
  Future<void> start({InternetAddress? bindAddress}) async {
    if (_socket != null) {
      return;
    }
    final socket = await RawDatagramSocket.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      listenPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    try {
      socket.joinMulticast(InternetAddress(kTapToShareMulticastGroup));
    } catch (_) {
      // Loopback or restricted interfaces may not support multicast join; unicast/broadcast still work.
    }

    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = socket.receive();
        if (dg != null) {
          _handleDatagram(dg);
        }
      }
    });

    _socket = socket;
  }

  /// Sends a 4-timestamp NTP-style `clock_ping` to [targetAddress]:[targetPort].
  void sendClockPing({
    required InternetAddress targetAddress,
    int targetPort = kTapToShareDefaultUdpPort,
  }) {
    final socket = _socket;
    if (socket == null) {
      return;
    }
    final payload = jsonEncode({
      'type': 'clock_ping',
      'senderFingerprint': localFingerprint,
      't1Us': _nowUs(),
    });
    socket.send(utf8.encode(payload), targetAddress, targetPort);
  }

  /// Broadcasts and unicasts a [PeerTapAnnouncement] to LAN peers (`AC-2`).
  void broadcastTapAnnouncement(
    PeerTapAnnouncement announcement, {
    List<String> knownPeerIps = const [],
    int targetPort = kTapToShareDefaultUdpPort,
    bool includeSubnetBroadcast = true,
  }) {
    final socket = _socket;
    if (socket == null) {
      return;
    }
    final bytes = utf8.encode(
      jsonEncode({
        'type': 'tap_announce',
        'payload': announcement.toJson(),
      }),
    );

    final sentTargets = <String>{};
    for (final rawIp in knownPeerIps) {
      final ip = rawIp.trim();
      if (ip.isEmpty || !sentTargets.add(ip)) {
        continue;
      }
      final parsed = InternetAddress.tryParse(ip);
      if (parsed != null && parsed.type == InternetAddressType.IPv4) {
        try {
          socket.send(bytes, parsed, targetPort);
        } catch (_) {}
      }
    }

    if (includeSubnetBroadcast) {
      try {
        socket.send(bytes, InternetAddress(kTapToShareMulticastGroup), targetPort);
      } catch (_) {}
      try {
        socket.send(bytes, InternetAddress('255.255.255.255'), targetPort);
      } catch (_) {}
    }
  }

  void _handleDatagram(Datagram dg) {
    final tRecvUs = _nowUs();
    Map<String, dynamic> decoded;
    try {
      final text = utf8.decode(dg.data, allowMalformed: true);
      final raw = jsonDecode(text);
      if (raw is! Map<String, dynamic>) {
        return;
      }
      decoded = raw;
    } catch (_) {
      return;
    }

    final type = decoded['type'] as String?;
    if (type == 'clock_ping') {
      final senderFp = (decoded['senderFingerprint'] as String?)?.trim().toUpperCase() ?? '';
      if (senderFp.isEmpty || senderFp == localFingerprint) {
        return;
      }
      final t1Us = (decoded['t1Us'] as num?)?.toInt();
      if (t1Us == null) {
        return;
      }
      final t3Us = _nowUs();
      final pongPayload = jsonEncode({
        'type': 'clock_pong',
        'senderFingerprint': localFingerprint,
        't1Us': t1Us,
        't2Us': tRecvUs,
        't3Us': t3Us,
      });
      try {
        _socket?.send(utf8.encode(pongPayload), dg.address, dg.port);
      } catch (_) {}
    } else if (type == 'clock_pong') {
      final senderFp = (decoded['senderFingerprint'] as String?)?.trim().toUpperCase() ?? '';
      if (senderFp.isEmpty || senderFp == localFingerprint) {
        return;
      }
      final t1Us = (decoded['t1Us'] as num?)?.toInt();
      final t2Us = (decoded['t2Us'] as num?)?.toInt();
      final t3Us = (decoded['t3Us'] as num?)?.toInt();
      if (t1Us == null || t2Us == null || t3Us == null) {
        return;
      }
      final estimate = clockEstimator.recordSample(
        senderFp,
        ClockSyncSample(
          t1LocalSendUs: t1Us,
          t2PeerRecvUs: t2Us,
          t3PeerSendUs: t3Us,
          t4LocalRecvUs: tRecvUs,
        ),
      );
      if (!_clockSyncController.isClosed) {
        _clockSyncController.add(estimate);
      }
    } else if (type == 'tap_announce') {
      final payloadMap = decoded['payload'];
      if (payloadMap is! Map<String, dynamic>) {
        return;
      }
      try {
        final announcement = PeerTapAnnouncement.fromJson(payloadMap);
        if (announcement.senderFingerprint == localFingerprint) {
          return;
        }
        if (!_announcementController.isClosed) {
          _announcementController.add(
            ReceivedUdpTapPacket(
              announcement: announcement,
              senderAddress: dg.address,
              senderPort: dg.port,
              receivedAtLocalUs: tRecvUs,
            ),
          );
        }
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
  }

  Future<void> dispose() async {
    await stop();
    await _announcementController.close();
    await _clockSyncController.close();
  }
}
