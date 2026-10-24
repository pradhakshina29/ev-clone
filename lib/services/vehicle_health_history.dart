import 'package:flutter/foundation.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import 'auth_service.dart';
import 'vehicle_ble_client.dart';

class HealthSample {
  const HealthSample({
    required this.time,
    required this.stateOfHealthPercent,
    required this.batteryTemperatureC,
    required this.batteryPercent,
  });

  final DateTime time;
  final double stateOfHealthPercent;
  final double batteryTemperatureC;
  final double batteryPercent;
}

/// Battery-health readings received over BLE during this session, per
/// vehicle. Memory only: nothing is stored or invented, and the history is
/// cleared on sign-out.
class VehicleHealthHistory extends ChangeNotifier {
  VehicleHealthHistory({
    required this._snapshots,
    this.interval = const Duration(seconds: 5),
    this.capacity = 360,
  });

  static final VehicleHealthHistory shared = VehicleHealthHistory(
    snapshots: VehicleBleClient.shared.snapshot,
  );

  /// Starts recording for the app; clears the history on sign-out.
  static void startShared() {
    if (shared._started) return;
    shared.start();
    AuthService().authStateChanges().listen((user) {
      if (user == null) shared.clear();
    });
  }

  final ValueListenable<VehicleStateSnapshot?> _snapshots;
  final Duration interval;
  final int capacity;
  final Map<String, List<HealthSample>> _samples = {};
  bool _started = false;

  List<HealthSample> samplesFor(String vehicleId) =>
      List.unmodifiable(_samples[vehicleId] ?? const <HealthSample>[]);

  void start() {
    if (_started) return;
    _started = true;
    _snapshots.addListener(_onSnapshot);
    _onSnapshot();
  }

  void clear() {
    _samples.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _snapshots.removeListener(_onSnapshot);
    super.dispose();
  }

  void _onSnapshot() {
    final snapshot = _snapshots.value;
    final health = snapshot?.state.health;
    if (snapshot == null || health == null) return;
    final time = DateTime.fromMillisecondsSinceEpoch(snapshot.timestampMillis);
    final samples = _samples.putIfAbsent(snapshot.vehicleId, () => []);
    if (samples.isNotEmpty && time.difference(samples.last.time) < interval) {
      return;
    }
    samples.add(
      HealthSample(
        time: time,
        stateOfHealthPercent: health.battery.stateOfHealthPercent,
        batteryTemperatureC: health.battery.temperatureC,
        batteryPercent: snapshot.state.batteryPercent,
      ),
    );
    if (samples.length > capacity) samples.removeAt(0);
    notifyListeners();
  }
}
