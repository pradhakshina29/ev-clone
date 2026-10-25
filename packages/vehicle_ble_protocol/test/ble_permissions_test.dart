import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vehicle_ble_protocol/ble_permissions.dart';

void main() {
  group('requiredBlePermissions', () {
    test('Android 11 and lower need location for both roles', () {
      for (final role in BleRole.values) {
        expect(requiredBlePermissions(role, 30), [
          androidFineLocation,
          androidCoarseLocation,
        ]);
      }
      expect(bleRequiresLocationServices(BleRole.central, 30), isTrue);
      expect(bleRequiresLocationServices(BleRole.peripheral, 30), isFalse);
    });

    test('Android 12+ central needs scan + connect and no location', () {
      for (final sdk in [31, 33, 36]) {
        expect(requiredBlePermissions(BleRole.central, sdk), [
          androidBluetoothScan,
          androidBluetoothConnect,
        ]);
        expect(bleRequiresLocationServices(BleRole.central, sdk), isFalse);
      }
    });

    test('Android 12+ peripheral needs advertise + connect', () {
      expect(requiredBlePermissions(BleRole.peripheral, 36), [
        androidBluetoothAdvertise,
        androidBluetoothConnect,
      ]);
    });
  });

  group('BlePermissionGate', () {
    BlePermissionGate gate(
      _FakePlatform platform, {
      BleRole role = BleRole.central,
      Duration requestTimeout = const Duration(seconds: 5),
    }) => BlePermissionGate(
      role: role,
      platform: platform,
      requestTimeout: requestTimeout,
      retryDelay: Duration.zero,
    );

    test(
      'Android 11: requests location, then treats Bluetooth as authorized',
      () async {
        final platform = _FakePlatform(sdk: 30)
          ..onRequest = (p) => {for (final x in p) x: 'granted'};

        expect(await gate(platform).ensure(), BlePermissionResult.granted);
        expect(platform.requests, [
          [androidFineLocation, androidCoarseLocation],
        ]);
      },
    );

    test('Android 11: reports Location services off', () async {
      final platform = _FakePlatform(sdk: 30, locationOn: false)
        ..granted.addAll([androidFineLocation, androidCoarseLocation]);

      expect(
        await gate(platform).ensure(),
        BlePermissionResult.locationServicesOff,
      );
      expect(platform.requests, isEmpty);
    });

    test('Android 12+: requests scan + connect, never location', () async {
      final platform = _FakePlatform(sdk: 31, locationOn: false)
        ..onRequest = (p) => {for (final x in p) x: 'granted'};

      expect(await gate(platform).ensure(), BlePermissionResult.granted);
      expect(platform.requests, [
        [androidBluetoothScan, androidBluetoothConnect],
      ]);
      expect(platform.locationChecks, 0);
    });

    test('Android 16 simulator: requests advertise + connect', () async {
      final platform = _FakePlatform(sdk: 36)
        ..onRequest = (p) => {for (final x in p) x: 'granted'};

      expect(
        await gate(platform, role: BleRole.peripheral).ensure(),
        BlePermissionResult.granted,
      );
      expect(platform.requests, [
        [androidBluetoothAdvertise, androidBluetoothConnect],
      ]);
    });

    test('does not show a dialog when already granted', () async {
      final platform = _FakePlatform(sdk: 33)
        ..granted.addAll([androidBluetoothScan, androidBluetoothConnect]);

      expect(await gate(platform).ensure(), BlePermissionResult.granted);
      expect(platform.requests, isEmpty);
    });

    test('distinguishes denied from permanently denied', () async {
      final denied = _FakePlatform(sdk: 31)
        ..onRequest = (p) => {for (final x in p) x: 'denied'};
      expect(await gate(denied).ensure(), BlePermissionResult.denied);

      final permanent = _FakePlatform(sdk: 31)
        ..onRequest = (p) => {
          androidBluetoothScan: 'permanentlyDenied',
          androidBluetoothConnect: 'granted',
        };
      expect(
        await gate(permanent).ensure(),
        BlePermissionResult.permanentlyDenied,
      );
    });

    test(
      'an interrupted request re-checks grants instead of hanging',
      () async {
        // Android answers with empty arrays when another dialog (the map's
        // location prompt) is open; that dialog grants location meanwhile.
        final platform = _FakePlatform(sdk: 30);
        platform.onRequest = (_) {
          platform.granted.addAll([androidFineLocation, androidCoarseLocation]);
          return const {};
        };

        expect(await gate(platform).ensure(), BlePermissionResult.granted);
        expect(platform.requests, hasLength(1));
      },
    );

    test('retries once after an interruption', () async {
      final platform = _FakePlatform(sdk: 31);
      var calls = 0;
      platform.onRequest = (p) =>
          calls++ == 0 ? const {} : {for (final x in p) x: 'granted'};

      expect(await gate(platform).ensure(), BlePermissionResult.granted);
      expect(platform.requests, hasLength(2));
    });

    test('a request that never completes times out as denied', () async {
      final platform = _FakePlatform(sdk: 31)..hangRequests = true;

      expect(
        await gate(
          platform,
          requestTimeout: const Duration(milliseconds: 10),
        ).ensure(),
        BlePermissionResult.denied,
      );
    });

    test('concurrent callers share one system request', () async {
      final release = Completer<Map<String, String>>();
      final platform = _FakePlatform(sdk: 31)..pending = release;
      final shared = gate(platform);

      final first = shared.ensure();
      final second = shared.ensure();
      await Future<void>.delayed(Duration.zero);
      release.complete({
        androidBluetoothScan: 'granted',
        androidBluetoothConnect: 'granted',
      });

      expect(await first, BlePermissionResult.granted);
      expect(await second, BlePermissionResult.granted);
      expect(platform.requests, hasLength(1));

      // A later call checks again rather than reusing the old result.
      platform.granted.clear();
      platform.pending = null;
      platform.onRequest = (p) => {for (final x in p) x: 'denied'};
      expect(await shared.ensure(), BlePermissionResult.denied);
    });
  });
}

class _FakePlatform implements BlePermissionPlatform {
  _FakePlatform({required this.sdk, this.locationOn = true});

  final int sdk;
  final bool locationOn;
  final Set<String> granted = {};
  final List<List<String>> requests = [];
  Map<String, String> Function(List<String>)? onRequest;
  Completer<Map<String, String>>? pending;
  bool hangRequests = false;
  int locationChecks = 0;

  @override
  Future<int> sdkInt() async => sdk;

  @override
  Future<Map<String, String>> check(List<String> permissions) async => {
    for (final p in permissions) p: granted.contains(p) ? 'granted' : 'denied',
  };

  @override
  Future<Map<String, String>> request(List<String> permissions) async {
    requests.add(permissions);
    if (hangRequests) return Completer<Map<String, String>>().future;
    final Map<String, String> result =
        await pending?.future ?? onRequest?.call(permissions) ?? const {};
    result.forEach((p, status) {
      if (status == 'granted') granted.add(p);
    });
    return result;
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    locationChecks++;
    return locationOn;
  }

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<void> openLocationSettings() async {}
}
