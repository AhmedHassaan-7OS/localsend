package org.localsend.localsend_app

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.wifi.WifiManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Streams hardware-timestamped motion sensor samples (`accelerometer`, `linear_acceleration`, `gyroscope`)
 * over `org.localsend.localsend_app/tap_sensors_events` when requested by the Tap-to-Share recorder or detector,
 * and holds a Wi-Fi MulticastLock while active so UDP multicast/broadcast packets are never dropped by Android Wi-Fi drivers.
 */
class TapSensorChannelHandler(private val context: Context) : EventChannel.StreamHandler, SensorEventListener {
    companion object {
        private const val CONTROL_CHANNEL = "org.localsend.localsend_app/tap_sensors_control"
        private const val EVENT_CHANNEL = "org.localsend.localsend_app/tap_sensors_events"
        private const val DEFAULT_SAMPLING_PERIOD_US = 5000 // 200 Hz
    }

    private var sensorManager: SensorManager? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var eventSink: EventChannel.EventSink? = null
    private var isListening = false
    private var hasHardwareGyro = false

    fun register(messenger: BinaryMessenger) {
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
        MethodChannel(messenger, CONTROL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "stop" -> {
                    stopListening()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        stopListening()
        eventSink = events
        val samplingPeriodUs = (arguments as? Map<*, *>)?.get("samplingPeriodUs") as? Int
            ?: DEFAULT_SAMPLING_PERIOD_US

        acquireMulticastLock()

        val manager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager ?: return
        sensorManager = manager

        manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
            manager.registerListener(this, it, samplingPeriodUs)
        }
        manager.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)?.let {
            manager.registerListener(this, it, samplingPeriodUs)
        }
        val gyroSensor = manager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        hasHardwareGyro = gyroSensor != null
        gyroSensor?.let {
            manager.registerListener(this, it, samplingPeriodUs)
        }
        isListening = true
    }

    override fun onCancel(arguments: Any?) {
        stopListening()
    }

    fun stopListening() {
        if (isListening) {
            sensorManager?.unregisterListener(this)
            isListening = false
        }
        releaseMulticastLock()
        eventSink = null
    }

    private fun acquireMulticastLock() {
        try {
            val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            if (multicastLock == null) {
                multicastLock = wifiManager.createMulticastLock("localsend_tap_to_share").apply {
                    setReferenceCounted(false)
                }
            }
            if (multicastLock?.isHeld == false) {
                multicastLock?.acquire()
            }
        } catch (_: Throwable) {
            // Ignore if permission or Wi-Fi service is unavailable on this device.
        }
    }

    private fun releaseMulticastLock() {
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        } catch (_: Throwable) {
        }
    }

    override fun onSensorChanged(event: SensorEvent) {
        val sink = eventSink ?: return
        val typeKey = when (event.sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> "accel"
            Sensor.TYPE_LINEAR_ACCELERATION -> "linear_accel"
            Sensor.TYPE_GYROSCOPE -> "gyro"
            else -> return
        }
        // event.timestamp is nanoseconds from the monotonic hardware clock -> convert to microseconds.
        val timestampUs = event.timestamp / 1000L
        sink.success(
            mapOf(
                "type" to typeKey,
                "timestampUs" to timestampUs,
                "x" to event.values[0].toDouble(),
                "y" to event.values[1].toDouble(),
                "z" to event.values[2].toDouble(),
                "iosRawInG" to false,
            )
        )
        // If this Android phone has no hardware gyroscope, emit a zero-gyro sample alongside accelerometer
        // so ImpactDetector's gyro stillness checks remain satisfied.
        if (!hasHardwareGyro && event.sensor.type == Sensor.TYPE_ACCELEROMETER) {
            sink.success(
                mapOf(
                    "type" to "gyro",
                    "timestampUs" to timestampUs,
                    "x" to 0.0,
                    "y" to 0.0,
                    "z" to 0.0,
                    "iosRawInG" to false,
                )
            )
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // No-op
    }
}
