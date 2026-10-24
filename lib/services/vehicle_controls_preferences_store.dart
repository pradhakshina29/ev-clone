import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/vehicle_controls.dart';
import 'data_service.dart';

/// One in-memory copy of each user's per-vehicle controls preferences, with a
/// single write queue.
///
/// The Controls page owns the settings (toggles, passenger profiles) and the
/// alert coordinator owns the alert fields (history and active keys). Both
/// save through this store, so neither overwrites the other's latest change.
class VehicleControlsPreferencesStore extends ChangeNotifier {
  VehicleControlsPreferencesStore(this._data);

  static final VehicleControlsPreferencesStore shared =
      VehicleControlsPreferencesStore(DataService());

  final DataService _data;
  final Map<String, VehicleControlsPreferences> _cache = {};
  final Map<String, Future<VehicleControlsPreferences>> _loading = {};
  Future<void> _writeQueue = Future<void>.value();

  static String _key(String uid, String vehicleId) => '$uid:$vehicleId';

  VehicleControlsPreferences? cached(String uid, String vehicleId) =>
      _cache[_key(uid, vehicleId)];

  /// Returns the cached copy, or reads it from the backend. [refresh] always
  /// reads, but keeps the alert fields already held here because they may
  /// not have reached the backend yet.
  Future<VehicleControlsPreferences> load(
    String uid,
    String vehicleId, {
    bool refresh = false,
  }) {
    final key = _key(uid, vehicleId);
    final cachedValue = _cache[key];
    if (cachedValue != null && !refresh) return Future.value(cachedValue);
    return _loading[key] ??= () async {
      try {
        final fetched = await _data.getVehicleControlsPreferences(
          uid: uid,
          vehicleId: vehicleId,
        );
        final current = _cache[key];
        final merged = current == null
            ? fetched
            : fetched.copyWith(
                alertHistory: current.alertHistory,
                activeAlertKeys: current.activeAlertKeys,
              );
        _cache[key] = merged;
        notifyListeners();
        return merged;
      } finally {
        unawaited(_loading.remove(key));
      }
    }();
  }

  /// Saves the Controls page settings. The alert fields always come from the
  /// store so the page cannot drop an alert recorded while it was open.
  Future<void> saveSettings(
    String uid,
    String vehicleId,
    VehicleControlsPreferences settings,
  ) {
    final key = _key(uid, vehicleId);
    final current = _cache[key];
    _cache[key] = current == null
        ? settings
        : settings.copyWith(
            alertHistory: current.alertHistory,
            activeAlertKeys: current.activeAlertKeys,
          );
    notifyListeners();
    return _write(uid, vehicleId);
  }

  /// Applies [update] to the alert fields and saves. Requires a loaded copy.
  Future<void> updateAlerts(
    String uid,
    String vehicleId,
    VehicleControlsPreferences Function(VehicleControlsPreferences current)
    update,
  ) {
    final key = _key(uid, vehicleId);
    final current = _cache[key];
    if (current == null) {
      return Future.error(StateError('Preferences for $key are not loaded.'));
    }
    final updated = update(current);
    _cache[key] = current.copyWith(
      alertHistory: updated.alertHistory,
      activeAlertKeys: updated.activeAlertKeys,
    );
    notifyListeners();
    return _write(uid, vehicleId);
  }

  /// Sends the latest copy when its turn in the queue comes, so queued
  /// writes never send an older version over a newer one.
  Future<void> _write(String uid, String vehicleId) {
    final operation = _writeQueue
        .catchError((Object _) {})
        .then((_) {
          final latest = _cache[_key(uid, vehicleId)];
          if (latest == null) return Future<void>.value();
          return _data.saveVehicleControlsPreferences(
            uid: uid,
            vehicleId: vehicleId,
            preferences: latest,
          );
        });
    _writeQueue = operation;
    return operation;
  }

  /// Forgets every cached copy, e.g. after sign-out.
  void clear() {
    _cache.clear();
    _loading.clear();
    notifyListeners();
  }
}
