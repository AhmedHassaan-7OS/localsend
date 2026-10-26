/// Transport protocols managed by the Tap-to-Share Transport Abstraction Layer (`Spec 009`).
///
/// Per rule `R2.5`, this layer never modifies LocalSend's core Rust HTTP server;
/// instead, it selects or establishes an IP link (`lanHttp`, `wifiDirect`, `multipeerConnectivity`, or `localHotspot`)
/// and hands the resulting `(ip, port, peerFingerprint)` endpoint to LocalSend's existing transfer pipeline.
enum TapTransportKind {
  /// Standard LocalSend HTTP/HTTPS transfer over shared Wi-Fi / LAN.
  lanHttp,

  /// Wi-Fi Direct P2P group (`Android ↔ Android` offline).
  wifiDirect,

  /// Apple MultipeerConnectivity / AWDL (`iOS/macOS ↔ iOS/macOS` offline).
  multipeerConnectivity,

  /// Ephemeral Local-Only Hotspot (`Android ↔ iOS` or `Mobile ↔ Desktop` offline fallback).
  localHotspot,

  /// No transport could be established.
  unavailable,
}

/// Platform families used to select the optimal offline P2P transport (`Spec 009`).
enum PeerPlatformKind {
  android,
  ios,
  macos,
  windows,
  linux
  ;

  bool get isApple => this == PeerPlatformKind.ios || this == PeerPlatformKind.macos;
}

/// Resolved IP endpoint ready for LocalSend's standard HTTP transfer pipeline.
class TapTransportEndpoint {
  final TapTransportKind transportKind;
  final String ip;
  final int port;
  final String peerFingerprint;

  const TapTransportEndpoint({
    required this.transportKind,
    required this.ip,
    required this.port,
    required this.peerFingerprint,
  });
}

/// Pluggable adapter capable of establishing a specific [TapTransportKind] link.
abstract class TapTransportAdapter {
  TapTransportKind get kind;

  Future<TapTransportEndpoint?> connect({
    required String peerFingerprint,
    required Duration timeout,
  });
}

/// Determines the ordered transport priority list for a pair of peers (`Spec 009`).
class TapTransportSelector {
  const TapTransportSelector();

  /// Returns the ordered list of [TapTransportKind] candidates to try.
  List<TapTransportKind> prioritizedTransports({
    required PeerPlatformKind localPlatform,
    required PeerPlatformKind peerPlatform,
    required bool isSameLanAvailable,
  }) {
    final candidates = <TapTransportKind>[];

    // AC-1: Always prefer existing shared LAN HTTP first when available.
    if (isSameLanAvailable) {
      candidates.add(TapTransportKind.lanHttp);
    }

    // AC-2: Platform-pair matrix for offline direct links.
    if (localPlatform == PeerPlatformKind.android && peerPlatform == PeerPlatformKind.android) {
      candidates.add(TapTransportKind.wifiDirect);
      candidates.add(TapTransportKind.localHotspot);
    } else if (localPlatform.isApple && peerPlatform.isApple) {
      candidates.add(TapTransportKind.multipeerConnectivity);
      candidates.add(TapTransportKind.localHotspot);
    } else {
      // Cross-ecosystem (e.g., Android <-> iOS, Mobile <-> Windows/Linux).
      candidates.add(TapTransportKind.localHotspot);
    }

    return List.unmodifiable(candidates);
  }
}

/// Orchestrates transport selection and automatic failover across registered [TapTransportAdapter]s (`Spec 009`).
class TapTransportOrchestrator {
  final TapTransportSelector selector;
  final Map<TapTransportKind, TapTransportAdapter> _adaptersByKind;
  final Duration perTransportTimeout;

  TapTransportOrchestrator({
    this.selector = const TapTransportSelector(),
    required List<TapTransportAdapter> adapters,
    this.perTransportTimeout = const Duration(seconds: 4),
  }) : _adaptersByKind = {for (final a in adapters) a.kind: a};

  /// Attempts each candidate transport in priority order until one returns a connected [TapTransportEndpoint] (`AC-3`).
  Future<TapTransportEndpoint?> establishEndpoint({
    required String peerFingerprint,
    required PeerPlatformKind localPlatform,
    required PeerPlatformKind peerPlatform,
    required bool isSameLanAvailable,
  }) async {
    final plan = selector.prioritizedTransports(
      localPlatform: localPlatform,
      peerPlatform: peerPlatform,
      isSameLanAvailable: isSameLanAvailable,
    );

    for (final kind in plan) {
      final adapter = _adaptersByKind[kind];
      if (adapter == null) {
        continue;
      }
      try {
        final endpoint = await adapter
            .connect(
              peerFingerprint: peerFingerprint,
              timeout: perTransportTimeout,
            )
            .timeout(perTransportTimeout, onTimeout: () => null);
        if (endpoint != null) {
          return endpoint;
        }
      } catch (_) {
        // AC-3: Continue to next fallback transport on error.
      }
    }
    return null;
  }
}
