package com.evsmartcompanion.vehicle_simulator

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.evsmartcompanion.vehicle_simulator/ble_diagnostics"
        private const val TAG = "VehicleSimulatorBLE"
    }

    private var blePermissions: BlePermissionsHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        blePermissions = BlePermissionsHandler(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "inspect") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                result.success(inspectBluetooth())
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (blePermissions?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun inspectBluetooth(): Map<String, Any?> {
        val packageManager = packageManager
        val bluetoothFeature =
            packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH)
        val bleFeature =
            packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        val advertiseGranted = hasPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
        val connectGranted = hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
        val manager = getSystemService(BluetoothManager::class.java)
        val adapter: BluetoothAdapter? = manager?.adapter
        var adapterState: Int? = null
        var multipleAdvertisementSupported: Boolean? = null
        var advertiserAvailable: Boolean? = null
        var adapterEnabled: Boolean? = null
        var adapterError: String? = null

        try {
            if (adapter != null) {
                adapterState = adapter.state
                multipleAdvertisementSupported =
                    adapter.isMultipleAdvertisementSupported
                if (connectGranted) {
                    adapterEnabled = adapter.isEnabled
                    if (advertiseGranted) {
                        advertiserAvailable = adapter.bluetoothLeAdvertiser != null
                    }
                }
            }
        } catch (error: SecurityException) {
            adapterError = "${error.javaClass.simpleName}: ${error.message}"
        }

        val diagnostics = mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "bluetoothFeature" to bluetoothFeature,
            "bleFeature" to bleFeature,
            "adapterAvailable" to (adapter != null),
            "adapterState" to adapterState,
            "adapterStateName" to adapterState?.let(::adapterStateName),
            "adapterEnabled" to adapterEnabled,
            "multipleAdvertisementSupported" to multipleAdvertisementSupported,
            "advertiserAvailable" to advertiserAvailable,
            "bluetoothAdvertisePermissionGranted" to advertiseGranted,
            "bluetoothConnectPermissionGranted" to connectGranted,
            "adapterError" to adapterError,
        )
        Log.i(TAG, "BLE diagnostics: $diagnostics")
        return diagnostics
    }

    private fun hasPermission(permission: String): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(this, permission) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

    private fun adapterStateName(state: Int): String = when (state) {
        BluetoothAdapter.STATE_OFF -> "OFF"
        BluetoothAdapter.STATE_TURNING_ON -> "TURNING_ON"
        BluetoothAdapter.STATE_ON -> "ON"
        BluetoothAdapter.STATE_TURNING_OFF -> "TURNING_OFF"
        15 -> "BLE_ON"
        else -> "UNKNOWN($state)"
    }
}
