import UIKit
import Flutter
import CoreMotion

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var tapSensorStreamHandler: TapSensorStreamHandler?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(
        name: "ios-delegate-channel",
        binaryMessenger: messenger
    )
    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        if call.method == "isReduceMotionEnabled" {
          result(UIAccessibility.isReduceMotionEnabled)
        } else {
          result(FlutterMethodNotImplemented)
        }
    }

    let sensorHandler = TapSensorStreamHandler()
    sensorHandler.register(with: messenger)
    tapSensorStreamHandler = sensorHandler

    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

/// Streams hardware-timestamped motion sensor samples (`accel`, `linear_accel`, `gyro`) on iOS
/// via `CMMotionManager` when subscribed by the Tap-to-Share recorder or detector.
final class TapSensorStreamHandler: NSObject, FlutterStreamHandler {
  private static let controlChannelName = "org.localsend.localsend_app/tap_sensors_control"
  private static let eventChannelName = "org.localsend.localsend_app/tap_sensors_events"
  private static let defaultSamplingPeriodUs = 5000 // 200 Hz

  private let motionManager = CMMotionManager()
  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.name = "org.localsend.tap_sensors_queue"
    q.maxConcurrentOperationCount = 1
    q.qualityOfService = .userInteractive
    return q
  }()
  private var eventSink: FlutterEventSink?

  func register(with messenger: FlutterBinaryMessenger) {
    let eventChannel = FlutterEventChannel(name: Self.eventChannelName, binaryMessenger: messenger)
    eventChannel.setStreamHandler(self)

    let controlChannel = FlutterMethodChannel(name: Self.controlChannelName, binaryMessenger: messenger)
    controlChannel.setMethodCallHandler { [weak self] call, result in
      if call.method == "stop" {
        self?.stopListening()
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    stopListening()
    eventSink = events

    let args = arguments as? [String: Any]
    let periodUs = (args?["samplingPeriodUs"] as? Int) ?? Self.defaultSamplingPeriodUs
    let intervalSeconds = max(Double(periodUs) / 1_000_000.0, 0.002)

    if motionManager.isAccelerometerAvailable {
      motionManager.accelerometerUpdateInterval = intervalSeconds
      motionManager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
        guard let data = data else { return }
        let timestampUs = Int64(data.timestamp * 1_000_000.0)
        DispatchQueue.main.async {
          self?.eventSink?([
            "type": "accel",
            "timestampUs": timestampUs,
            "x": data.acceleration.x,
            "y": data.acceleration.y,
            "z": data.acceleration.z,
            "iosRawInG": true
          ])
        }
      }
    }

    if motionManager.isDeviceMotionAvailable {
      motionManager.deviceMotionUpdateInterval = intervalSeconds
      motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
        guard let motion = motion else { return }
        let timestampUs = Int64(motion.timestamp * 1_000_000.0)
        DispatchQueue.main.async {
          self?.eventSink?([
            "type": "linear_accel",
            "timestampUs": timestampUs,
            "x": motion.userAcceleration.x,
            "y": motion.userAcceleration.y,
            "z": motion.userAcceleration.z,
            "iosRawInG": true
          ])
        }
      }
    }

    if motionManager.isGyroAvailable {
      motionManager.gyroUpdateInterval = intervalSeconds
      motionManager.startGyroUpdates(to: queue) { [weak self] data, _ in
        guard let data = data else { return }
        let timestampUs = Int64(data.timestamp * 1_000_000.0)
        DispatchQueue.main.async {
          self?.eventSink?([
            "type": "gyro",
            "timestampUs": timestampUs,
            "x": data.rotationRate.x,
            "y": data.rotationRate.y,
            "z": data.rotationRate.z,
            "iosRawInG": false
          ])
        }
      }
    }

    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopListening()
    return nil
  }

  func stopListening() {
    if motionManager.isAccelerometerActive {
      motionManager.stopAccelerometerUpdates()
    }
    if motionManager.isDeviceMotionActive {
      motionManager.stopDeviceMotionUpdates()
    }
    if motionManager.isGyroActive {
      motionManager.stopGyroUpdates()
    }
    eventSink = nil
  }
}
