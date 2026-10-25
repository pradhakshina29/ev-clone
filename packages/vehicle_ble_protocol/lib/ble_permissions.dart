import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android runtime permissions used by the BLE central (app) and peripheral
/// (simulator).
const androidBluetoothScan = 'android.permission.BLUETOOTH_SCAN';
const androidBluetoothConnect = 'android.permission.BLUETOOTH_CONNECT';
const androidBluetoothAdvertise = 'android.permission.BLUETOOTH_ADVERTISE';
const androidFineLocation = 'android.permission.ACCESS_FINE_LOCATION';
const androidCoarseLocation = 'android.permission.ACCESS_COARSE_LOCATION';

/// Android 12 (API 31) introduced BLUETOOTH_SCAN/CONNECT/ADVERTISE.
const androidSdkS = 31;

enum BleRole { central, peripheral }

enum BlePermissionResult {
  granted,
  denied,
  permanentlyDenied,
  locationServicesOff,
}

/// Runtime permissions [role] needs on an Android device running [sdkInt].
///
/// Android 11 and lower: BLUETOOTH/BLUETOOTH_ADMIN are install-time and
/// location is the runtime gate (the bluetooth_low_energy plugin reports
/// both roles as unauthorized without it). Android 12+: the new Bluetooth
/// permissions, without location.
List<String> requiredBlePermissions(BleRole role, int sdkInt) {
  if (sdkInt < androidSdkS) {
    return const [androidFineLocation, androidCoarseLocation];
  }
  return switch (role) {
    BleRole.central => const [androidBluetoothScan, androidBluetoothConnect],
    BleRole.peripheral => const [
      androidBluetoothAdvertise,
      androidBluetoothConnect,
    ],
  };
}

/// Scanning on Android 11 and lower silently returns nothing while the
/// system Location toggle is off, even with the permission granted.
bool bleRequiresLocationServices(BleRole role, int sdkInt) =>
    role == BleRole.central && sdkInt < androidSdkS;

/// Native side of the permission flow, implemented in each app's
/// MainActivity. Status values are 'granted', 'denied' or
/// 'permanentlyDenied'; an empty request result means Android interrupted
/// the request (usually because another permission dialog was open).
abstract class BlePermissionPlatform {
  Future<int> sdkInt();
  Future<Map<String, String>> check(List<String> permissions);
  Future<Map<String, String>> request(List<String> permissions);
  Future<bool> isLocationServiceEnabled();
  Future<void> openAppSettings();
  Future<void> openLocationSettings();
}

class MethodChannelBlePermissionPlatform implements BlePermissionPlatform {
  const MethodChannelBlePermissionPlatform();

  static const _channel = MethodChannel('vehicle_ble_protocol/ble_permissions');

  @override
  Future<int> sdkInt() async =>
      await _channel.invokeMethod<int>('sdkInt') ?? androidSdkS;

  @override
  Future<Map<String, String>> check(List<String> permissions) =>
      _statuses('check', permissions);

  @override
  Future<Map<String, String>> request(List<String> permissions) =>
      _statuses('request', permissions);

  Future<Map<String, String>> _statuses(
    String method,
    List<String> permissions,
  ) async {
    final result = await _channel.invokeMapMethod<String, String>(method, {
      'permissions': permissions,
    });
    return result ?? const {};
  }

  @override
  Future<bool> isLocationServiceEnabled() async =>
      await _channel.invokeMethod<bool>('isLocationServiceEnabled') ?? true;

  @override
  Future<void> openAppSettings() => _channel.invokeMethod('openAppSettings');

  @override
  Future<void> openLocationSettings() =>
      _channel.invokeMethod('openLocationSettings');
}

/// Requests the Bluetooth permissions for [role] and always completes:
/// interrupted or unanswered requests fall back to re-reading the current
/// grants instead of waiting forever.
class BlePermissionGate {
  BlePermissionGate({
    required this.role,
    BlePermissionPlatform? platform,
    this.requestTimeout = const Duration(seconds: 60),
    this.retryDelay = const Duration(milliseconds: 600),
  }) : platform = platform ?? const MethodChannelBlePermissionPlatform();

  final BleRole role;
  final BlePermissionPlatform platform;
  final Duration requestTimeout;
  final Duration retryDelay;
  Future<BlePermissionResult>? _inFlight;

  /// Concurrent callers share one request, so a reconnect timer can never
  /// start a second system dialog on top of the first.
  Future<BlePermissionResult> ensure() =>
      _inFlight ??= _ensure().whenComplete(() => _inFlight = null);

  Future<BlePermissionResult> _ensure() async {
    final sdkInt = await platform.sdkInt();
    final required = requiredBlePermissions(role, sdkInt);
    var statuses = await platform.check(required);
    if (!_allGranted(required, statuses)) {
      statuses = await _request(required);
    }
    debugPrint('[BLE permissions] sdk=$sdkInt role=$role $statuses');
    if (!_allGranted(required, statuses)) {
      return required.any((p) => statuses[p] == 'permanentlyDenied')
          ? BlePermissionResult.permanentlyDenied
          : BlePermissionResult.denied;
    }
    if (bleRequiresLocationServices(role, sdkInt) &&
        !await platform.isLocationServiceEnabled()) {
      return BlePermissionResult.locationServicesOff;
    }
    return BlePermissionResult.granted;
  }

  Future<Map<String, String>> _request(List<String> required) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      Map<String, String> result;
      try {
        result = await platform.request(required).timeout(requestTimeout);
      } on TimeoutException {
        result = const {};
      }
      if (required.every(result.containsKey)) return result;
      // Interrupted or unanswered: another dialog (for example the map's
      // location prompt) may already have granted what is needed.
      debugPrint('[BLE permissions] request interrupted; re-checking.');
      await Future<void>.delayed(retryDelay);
      final current = await platform.check(required);
      if (_allGranted(required, current)) return current;
    }
    return platform.check(required);
  }

  static bool _allGranted(
    List<String> required,
    Map<String, String> statuses,
  ) => required.every((permission) => statuses[permission] == 'granted');
}
