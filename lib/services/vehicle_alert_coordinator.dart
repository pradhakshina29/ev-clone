import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import '../models/vehicle_controls.dart';
import '../widgets/vehicle_alert_dialog.dart';
import 'auth_service.dart';
import 'vehicle_ble_client.dart';
import 'vehicle_controls_preferences_store.dart';

/// Watches the shared BLE snapshot for the whole app and raises vehicle
/// alerts on whichever screen is open.
///
/// Warnings and critical alerts open a must-acknowledge dialog, one at a
/// time; info alerts show a SnackBar. Every alert is saved in the per-vehicle
/// alert history with the time it was shown and acknowledged.
class VehicleAlertCoordinator {
  VehicleAlertCoordinator({
    required this._snapshots,
    required this._store,
    required this._navigatorKey,
    required this._currentUid,
    this._messengerKey,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static VehicleAlertCoordinator? _shared;
  static const _retryLoadAfter = Duration(seconds: 30);

  /// Starts the app-wide coordinator once, using the shared BLE client.
  static void startShared({
    required GlobalKey<NavigatorState> navigatorKey,
    required GlobalKey<ScaffoldMessengerState> messengerKey,
  }) {
    if (_shared != null) return;
    final coordinator = VehicleAlertCoordinator(
      snapshots: VehicleBleClient.shared.snapshot,
      store: VehicleControlsPreferencesStore.shared,
      navigatorKey: navigatorKey,
      messengerKey: messengerKey,
      currentUid: () => AuthService().currentUser?.uid,
    )..start();
    AuthService().authStateChanges().listen((user) {
      if (user == null) {
        coordinator.reset();
        VehicleControlsPreferencesStore.shared.clear();
      }
    });
    _shared = coordinator;
  }

  final ValueListenable<VehicleStateSnapshot?> _snapshots;
  final VehicleControlsPreferencesStore _store;
  final GlobalKey<NavigatorState> _navigatorKey;
  final GlobalKey<ScaffoldMessengerState>? _messengerKey;
  final String? Function() _currentUid;
  final DateTime Function() _clock;

  final Queue<VehicleAlert> _queue = Queue<VehicleAlert>();
  String? _uid;
  String? _vehicleId;
  VehicleAlertEngine? _engine;
  bool _loading = false;
  // False while the preferences could not be read: alerts still show, but
  // nothing is written so the saved settings are never replaced by defaults.
  bool _persist = false;
  DateTime? _retryLoadAt;
  VehicleControlsPreferences _unsaved = const VehicleControlsPreferences();
  VehicleStateSnapshot? _pending;
  Route<bool>? _openDialog;
  int _generation = 0;

  /// Alerts waiting behind the open dialog.
  int get queuedCount => _queue.length;
  bool get isShowingDialog => _openDialog != null;

  void start() => _snapshots.addListener(_onSnapshot);

  void dispose() {
    _snapshots.removeListener(_onSnapshot);
    reset();
  }

  /// Drops queued alerts and closes an open dialog without recording an
  /// acknowledgement, e.g. on sign-out.
  void reset() {
    _generation++;
    _queue.clear();
    final dialog = _openDialog;
    _openDialog = null;
    if (dialog != null && dialog.isActive) {
      dialog.navigator?.removeRoute(dialog);
    }
    _uid = null;
    _vehicleId = null;
    _engine = null;
    _loading = false;
    _persist = false;
    _retryLoadAt = null;
    _unsaved = const VehicleControlsPreferences();
    _pending = null;
  }

  void _onSnapshot() {
    final uid = _currentUid();
    if (uid == null) {
      if (_uid != null) reset();
      return;
    }
    final snapshot = _snapshots.value;
    if (snapshot == null) return;
    if (uid != _uid || snapshot.vehicleId != _vehicleId) {
      reset();
      _uid = uid;
      _vehicleId = snapshot.vehicleId;
    }
    if (_engine == null) {
      _pending = snapshot;
      _load();
      return;
    }
    if (!_persist &&
        _retryLoadAt != null &&
        !_clock().isBefore(_retryLoadAt!)) {
      _load();
    }
    _process(snapshot);
  }

  void _load() {
    if (_loading) return;
    final uid = _uid!;
    final vehicleId = _vehicleId!;
    final generation = _generation;
    _loading = true;
    _store
        .load(uid, vehicleId)
        .then(
          (preferences) {
            if (generation != _generation) return;
            _loading = false;
            _persist = true;
            _retryLoadAt = null;
            if (_engine == null) {
              _engine = VehicleAlertEngine(
                activeKeys: preferences.activeAlertKeys,
              );
            } else {
              // Saves what was recorded while the backend was unreachable.
              final ids = preferences.alertHistory.map((alert) => alert.id);
              final missing = _unsaved.alertHistory
                  .where((alert) => !ids.contains(alert.id))
                  .toList();
              _save(
                (current) => current.copyWith(
                  activeAlertKeys: _sortedKeys(),
                  alertHistory: [
                    ...missing,
                    ...current.alertHistory,
                  ].take(50).toList(growable: false),
                ),
              );
            }
            _processPending();
          },
          onError: (Object error) {
            if (generation != _generation) return;
            debugPrint(
              '[Vehicle Alerts] Preferences read failed: ${error.runtimeType}',
            );
            _loading = false;
            _retryLoadAt = _clock().add(_retryLoadAfter);
            _engine ??= VehicleAlertEngine();
            _processPending();
          },
        );
  }

  void _processPending() {
    final pending = _pending;
    _pending = null;
    if (pending != null) _process(pending);
  }

  VehicleControlsPreferences get _preferences => _persist
      ? _store.cached(_uid!, _vehicleId!) ?? const VehicleControlsPreferences()
      : _unsaved;

  List<String> _sortedKeys() => _engine!.activeKeys.toList()..sort();

  void _process(VehicleStateSnapshot snapshot) {
    final engine = _engine;
    if (engine == null) return;
    final newAlerts = engine.evaluate(snapshot);
    final activeKeys = _sortedKeys();
    final preferences = _preferences;
    final keysChanged = !setEquals(
      preferences.activeAlertKeys.toSet(),
      activeKeys.toSet(),
    );
    final ids = preferences.alertHistory.map((alert) => alert.id).toSet();
    final unseen = newAlerts.where((alert) => !ids.contains(alert.id)).toList();
    if (unseen.isEmpty && !keysChanged) return;

    _save(
      (current) => current.copyWith(
        activeAlertKeys: activeKeys,
        alertHistory: unseen.isEmpty
            ? current.alertHistory
            : [
                ...unseen.reversed,
                ...current.alertHistory,
              ].take(50).toList(growable: false),
      ),
    );

    for (final alert in unseen) {
      if (!_isEnabled(preferences, alert)) continue;
      if (alert.requiresAcknowledgement) {
        _queue.add(alert);
      } else {
        _messengerKey?.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('${alert.title}: ${alert.message}')),
          );
      }
    }
    unawaited(_showNext());
  }

  void _save(
    VehicleControlsPreferences Function(VehicleControlsPreferences current)
    update,
  ) {
    if (!_persist) {
      _unsaved = update(_unsaved);
      return;
    }
    unawaited(
      _store.updateAlerts(_uid!, _vehicleId!, update).catchError((
        Object error,
      ) {
        debugPrint(
          '[Vehicle Alerts] Alert history save failed: ${error.runtimeType}',
        );
      }),
    );
  }

  void _updateHistoryEntry(
    String id,
    VehicleAlert Function(VehicleAlert alert) update,
  ) {
    _save(
      (current) => current.copyWith(
        alertHistory: [
          for (final alert in current.alertHistory)
            alert.id == id ? update(alert) : alert,
        ],
      ),
    );
  }

  static bool _isEnabled(
    VehicleControlsPreferences preferences,
    VehicleAlert alert,
  ) {
    if (!preferences.notificationsEnabled) return false;
    final kind = alert.kind;
    if (kind.startsWith('door_') ||
        kind.startsWith('motor_') ||
        kind.startsWith('tire_') ||
        kind.startsWith('brake_')) {
      return preferences.safetyAlertsEnabled;
    }
    if (kind.startsWith('battery_')) return preferences.batteryAlertsEnabled;
    if (kind.startsWith('charging_')) return preferences.chargingAlertsEnabled;
    return kind.startsWith('software_');
  }

  Future<void> _showNext() async {
    if (_openDialog != null || _queue.isEmpty) return;
    final navigator = _navigatorKey.currentState;
    final overlayContext = navigator?.overlay?.context;
    if (navigator == null || overlayContext == null) return;

    final generation = _generation;
    final alert = _queue.removeFirst();
    final shownAt = _clock();
    _updateHistoryEntry(alert.id, (saved) => saved.copyWith(shownAt: shownAt));
    final route = DialogRoute<bool>(
      context: overlayContext,
      barrierDismissible: false,
      barrierLabel: MaterialLocalizations.of(
        overlayContext,
      ).modalBarrierDismissLabel,
      themes: InheritedTheme.capture(
        from: overlayContext,
        to: navigator.context,
      ),
      builder: (_) => VehicleAlertDialog(alert: alert, shownAt: shownAt),
    );
    _openDialog = route;
    final acknowledged = await navigator.push(route);
    if (generation != _generation) return;
    _openDialog = null;
    if (acknowledged == true) {
      final acknowledgedAt = _clock();
      _updateHistoryEntry(
        alert.id,
        (saved) => saved.copyWith(acknowledgedAt: acknowledgedAt),
      );
    }
    await _showNext();
  }
}
