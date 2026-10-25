package com.evsmartcompanion.vehicle_simulator

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Backs vehicle_ble_protocol's BlePermissionGate. Unlike the BLE plugin's
 * authorize(), the pending result is stored before the system request is
 * made, so an interrupted request (Android answers with empty arrays when
 * another permission dialog is already open) completes with an empty map
 * instead of leaving Dart waiting forever.
 */
class BlePermissionsHandler(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "vehicle_ble_protocol/ble_permissions"
        const val REQUEST_CODE = 0x4556
        private const val PREFS = "ble_permissions"
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingPermissions: List<String> = emptyList()
    private var rationaleBeforeRequest: Map<String, Boolean> = emptyMap()

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            "check" -> result.success(permissionsOf(call).associateWith(::currentStatus))
            "request" -> request(permissionsOf(call), result)
            "isLocationServiceEnabled" -> result.success(isLocationEnabled())
            "openAppSettings" -> {
                activity.startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", activity.packageName, null)
                    )
                )
                result.success(null)
            }
            "openLocationSettings" -> {
                activity.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun permissionsOf(call: MethodCall): List<String> =
        call.argument<List<String>>("permissions") ?: emptyList()

    private fun isGranted(permission: String) =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun currentStatus(permission: String) = if (isGranted(permission)) "granted" else "denied"

    private fun request(permissions: List<String>, result: MethodChannel.Result) {
        val missing = permissions.filterNot(::isGranted)
        if (missing.isEmpty()) {
            result.success(permissions.associateWith { "granted" })
            return
        }
        // Only one of our requests can be outstanding; release the older one.
        pendingResult?.success(emptyMap<String, String>())
        pendingResult = result
        pendingPermissions = permissions
        rationaleBeforeRequest =
            missing.associateWith { activity.shouldShowRequestPermissionRationale(it) }
        try {
            activity.requestPermissions(missing.toTypedArray(), REQUEST_CODE)
        } catch (error: Exception) {
            pendingResult = null
            result.error("REQUEST_FAILED", error.message, null)
        }
    }

    /** Returns true when [requestCode] belonged to this handler. */
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingResult ?: return true
        pendingResult = null
        if (permissions.isEmpty() || grantResults.isEmpty()) {
            result.success(emptyMap<String, String>())
            return true
        }
        val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        val statuses = mutableMapOf<String, String>()
        permissions.forEachIndexed { index, permission ->
            statuses[permission] = if (grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED) {
                "granted"
            } else {
                // Android stops showing the dialog once rationale flips back to
                // false after a denial. A first-time dismissal also reports
                // false, so only count it as permanent after an earlier ask.
                val askedBefore = prefs.getBoolean(permission, false)
                val rationaleNow = activity.shouldShowRequestPermissionRationale(permission)
                if (!rationaleNow && (askedBefore || rationaleBeforeRequest[permission] == true)) {
                    "permanentlyDenied"
                } else {
                    "denied"
                }
            }
            editor.putBoolean(permission, true)
        }
        editor.apply()
        // Permissions that were already granted were not part of the request.
        for (permission in pendingPermissions) {
            statuses.getOrPut(permission) { currentStatus(permission) }
        }
        result.success(statuses)
        return true
    }

    private fun isLocationEnabled(): Boolean {
        val manager = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager?
            ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.isLocationEnabled
        } else {
            @Suppress("DEPRECATION")
            Settings.Secure.getInt(
                activity.contentResolver,
                Settings.Secure.LOCATION_MODE,
                Settings.Secure.LOCATION_MODE_OFF
            ) != Settings.Secure.LOCATION_MODE_OFF
        }
    }
}
