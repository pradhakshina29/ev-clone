import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vehicle_ble_protocol/ble_permissions.dart';

import 'package:flutter_application_2/services/vehicle_ble_client.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  VehicleBleClient clientFor(_FakePlatform platform) {
    final client = VehicleBleClient(
      permissionGate: BlePermissionGate(
        role: BleRole.central,
        platform: platform,
        retryDelay: Duration.zero,
      ),
    );
    addTearDown(client.dispose);
    return client;
  }

  test('permanently denied permissions offer Open settings', () async {
    final platform = _FakePlatform(sdk: 30, requestStatus: 'permanentlyDenied');
    final client = clientFor(platform);

    await client.start('EV002', deviceName: 'EV-Simulator-02');

    expect(client.phase, VehicleBlePhase.error);
    expect(client.error, contains('Open Settings'));
    expect(client.recoveryAction, VehicleBleRecoveryAction.openAppSettings);
    await client.performRecoveryAction();
    expect(platform.openedAppSettings, isTrue);
  });

  test('a denied request leaves a retryable error, not authorizing', () async {
    final client = clientFor(_FakePlatform(sdk: 31, requestStatus: 'denied'));

    await client.start('EV002');

    expect(client.phase, VehicleBlePhase.error);
    expect(client.error, contains('Bluetooth permissions are required'));
    expect(client.recoveryAction, isNull);
  });

  test('Location off on Android 11 offers Location settings', () async {
    final platform = _FakePlatform(
      sdk: 30,
      requestStatus: 'granted',
      locationOn: false,
    );
    final client = clientFor(platform);

    await client.start('EV002');

    expect(client.phase, VehicleBlePhase.error);
    expect(client.error, contains('Turn on Location'));
    expect(
      client.recoveryAction,
      VehicleBleRecoveryAction.openLocationSettings,
    );
    await client.performRecoveryAction();
    expect(platform.openedLocationSettings, isTrue);
  });

  test('an interrupted request never leaves the client authorizing', () async {
    final client = clientFor(_FakePlatform(sdk: 30, requestStatus: null));

    await client.start('EV002');

    expect(client.phase, isNot(VehicleBlePhase.authorizing));
    expect(client.phase, VehicleBlePhase.error);
  });

  test('matches the advertised simulator name like the web chooser', () {
    expect(
      matchesVehicleSimulatorName('EV-Simulator-02', 'EV-Simulator-02'),
      isTrue,
    );
    expect(
      matchesVehicleSimulatorName(' ev-simulator-02 ', 'EV-Simulator-02'),
      isTrue,
    );
    expect(
      matchesVehicleSimulatorName('EV-Simulator-01', 'EV-Simulator-02'),
      isFalse,
    );
    expect(matchesVehicleSimulatorName(null, 'EV-Simulator-02'), isFalse);
  });
}

class _FakePlatform implements BlePermissionPlatform {
  _FakePlatform({
    required this.sdk,
    required this.requestStatus,
    this.locationOn = true,
  });

  final int sdk;

  /// Status every request returns; null simulates an interrupted request.
  final String? requestStatus;
  final bool locationOn;
  final Set<String> _granted = {};
  bool openedAppSettings = false;
  bool openedLocationSettings = false;

  @override
  Future<int> sdkInt() async => sdk;

  @override
  Future<Map<String, String>> check(List<String> permissions) async => {
    for (final p in permissions) p: _granted.contains(p) ? 'granted' : 'denied',
  };

  @override
  Future<Map<String, String>> request(List<String> permissions) async {
    final status = requestStatus;
    if (status == null) return const {};
    if (status == 'granted') _granted.addAll(permissions);
    return {for (final p in permissions) p: status};
  }

  @override
  Future<bool> isLocationServiceEnabled() async => locationOn;

  @override
  Future<void> openAppSettings() async => openedAppSettings = true;

  @override
  Future<void> openLocationSettings() async => openedLocationSettings = true;
}
