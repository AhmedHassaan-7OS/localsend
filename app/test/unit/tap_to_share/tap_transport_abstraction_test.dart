import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/tap_to_share/tap_transport_abstraction.dart';

class _FakeTransportAdapter implements TapTransportAdapter {
  @override
  final TapTransportKind kind;
  final bool shouldSucceed;
  final String ip;

  const _FakeTransportAdapter({
    required this.kind,
    required this.shouldSucceed,
    this.ip = '192.168.49.1',
  });

  @override
  Future<TapTransportEndpoint?> connect({
    required String peerFingerprint,
    required Duration timeout,
  }) async {
    if (!shouldSucceed) {
      return null;
    }
    return TapTransportEndpoint(
      transportKind: kind,
      ip: ip,
      port: 53317,
      peerFingerprint: peerFingerprint,
    );
  }
}

void main() {
  const selector = TapTransportSelector();

  test('AC-1: Always selects lanHttp first when isSameLanAvailable is true across all platform pairs', () {
    for (final local in PeerPlatformKind.values) {
      for (final peer in PeerPlatformKind.values) {
        final plan = selector.prioritizedTransports(
          localPlatform: local,
          peerPlatform: peer,
          isSameLanAvailable: true,
        );
        expect(plan.first, TapTransportKind.lanHttp);
      }
    }
  });

  test('AC-2: Offline platform-pair matrix selects wifiDirect, multipeerConnectivity, or localHotspot accurately', () {
    final androidToAndroid = selector.prioritizedTransports(
      localPlatform: PeerPlatformKind.android,
      peerPlatform: PeerPlatformKind.android,
      isSameLanAvailable: false,
    );
    expect(androidToAndroid.first, TapTransportKind.wifiDirect);

    final iosToIos = selector.prioritizedTransports(
      localPlatform: PeerPlatformKind.ios,
      peerPlatform: PeerPlatformKind.ios,
      isSameLanAvailable: false,
    );
    expect(iosToIos.first, TapTransportKind.multipeerConnectivity);

    final iosToMac = selector.prioritizedTransports(
      localPlatform: PeerPlatformKind.ios,
      peerPlatform: PeerPlatformKind.macos,
      isSameLanAvailable: false,
    );
    expect(iosToMac.first, TapTransportKind.multipeerConnectivity);

    final androidToIos = selector.prioritizedTransports(
      localPlatform: PeerPlatformKind.android,
      peerPlatform: PeerPlatformKind.ios,
      isSameLanAvailable: false,
    );
    expect(androidToIos.first, TapTransportKind.localHotspot);
  });

  test('AC-3: Automatically falls back to localHotspot when primary offline transport fails', () async {
    final orchestrator = TapTransportOrchestrator(
      adapters: const [
        _FakeTransportAdapter(
          kind: TapTransportKind.wifiDirect,
          shouldSucceed: false,
        ),
        _FakeTransportAdapter(
          kind: TapTransportKind.localHotspot,
          shouldSucceed: true,
          ip: '192.168.43.1',
        ),
      ],
    );

    final endpoint = await orchestrator.establishEndpoint(
      peerFingerprint: 'PEER_ANDROID_2',
      localPlatform: PeerPlatformKind.android,
      peerPlatform: PeerPlatformKind.android,
      isSameLanAvailable: false,
    );

    expect(endpoint, isNotNull);
    expect(endpoint!.transportKind, TapTransportKind.localHotspot);
    expect(endpoint.ip, '192.168.43.1');
  });
}
