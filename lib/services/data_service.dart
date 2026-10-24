import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models/charging_card.dart';
import '../models/user_model.dart';
import '../models/vehicle.dart';
import '../models/vehicle_controls.dart';
import '../models/vehicle_health.dart';
import 'api/api_client.dart';

/// The app's data layer, backed by the EV Smart Companion API.
///
/// Live vehicle measurements are not here: they come only from
/// [VehicleBleClient.shared]. The `uid` parameters are kept so screens did not
/// change; the server identifies the user from the access token and
/// enforces ownership of every vehicle.
class DataService {
  DataService({ApiClient? api, Duration? pollInterval})
    : _api = api ?? ApiClient(),
      _pollInterval = pollInterval ?? const Duration(seconds: 15);

  final ApiClient _api;
  final Duration _pollInterval;

  // Shared by every DataService so a write in one screen refreshes the others.
  static final StreamController<void> _changes =
      StreamController<void>.broadcast();

  void _notifyChanged() => _changes.add(null);

  /// Refetches every active watch stream now (used by pull-to-refresh).
  Future<void> refresh() async => _notifyChanged();

  /// A stream that fetches immediately, refetches every [_pollInterval] while
  /// listened to and right after any app write, skips identical results and
  /// keeps retrying after errors.
  Stream<T> _watch<T>(
    Future<Object?> Function() fetchRaw,
    T Function(Object? raw) map,
  ) {
    late StreamController<T> controller;
    Timer? timer;
    StreamSubscription<void>? changes;
    var inFlight = false;
    var refetchQueued = false;
    String? lastFingerprint;

    Future<void> refresh() async {
      if (inFlight) {
        refetchQueued = true;
        return;
      }
      inFlight = true;
      try {
        final raw = await fetchRaw();
        final fingerprint = jsonEncode(raw);
        if (!controller.isClosed && fingerprint != lastFingerprint) {
          lastFingerprint = fingerprint;
          controller.add(map(raw));
        }
      } catch (error, stackTrace) {
        lastFingerprint = null;
        if (!controller.isClosed) controller.addError(error, stackTrace);
      } finally {
        inFlight = false;
        if (refetchQueued && !controller.isClosed) {
          refetchQueued = false;
          unawaited(refresh());
        }
      }
    }

    controller = StreamController<T>(
      onListen: () {
        unawaited(refresh());
        timer = Timer.periodic(_pollInterval, (_) => unawaited(refresh()));
        changes = _changes.stream.listen((_) => unawaited(refresh()));
      },
      onCancel: () async {
        timer?.cancel();
        await changes?.cancel();
      },
    );
    return controller.stream;
  }

  static Map<String, dynamic> _map(Object? value) =>
      Map<String, dynamic>.from(value as Map);

  static List<Map<String, dynamic>> _list(Object? value) =>
      (value as List).map(_map).toList(growable: false);

  static Vehicle _vehicle(Object? value) {
    final map = _map(value);
    return Vehicle.fromMap(map, id: map['id'] as String? ?? '');
  }

  static Vehicle? _vehicleOrNull(Object? value) =>
      value == null ? null : _vehicle(value);

  static ChargingCard? _cardOrNull(Object? value) {
    if (value == null) return null;
    final map = _map(value);
    return ChargingCard.fromMap(map, id: map['id'] as String? ?? '');
  }

  static String _utc(DateTime value) => value.toUtc().toIso8601String();

  static String _vehiclePath(String vehicleId) {
    final normalized = vehicleId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(vehicleId, 'vehicleId', 'Cannot be empty.');
    }
    return '/v1/vehicles/${Uri.encodeComponent(normalized)}';
  }

  // ---------------------------------------------------------------- profile

  Future<Object?> _profileRaw() async {
    try {
      return await _api.get('/v1/me');
    } on ApiException catch (error) {
      if (error.code == 'profile_not_found') return null;
      rethrow;
    }
  }

  static UserModel? _profile(Object? raw) =>
      raw == null ? null : UserModel.fromMap(_map(raw));

  Future<UserModel?> getUserProfile(String uid) async =>
      _profile(await _profileRaw());

  Stream<UserModel?> watchUserProfile(String uid) =>
      _watch(_profileRaw, _profile);

  /// Sign-up: verifies the vehicle, claims it and creates the profile.
  Future<Vehicle> verifyAndCreateUserProfile({
    required String uid,
    required String name,
    required String email,
    required String phone,
    required String registrationNumber,
    required String model,
    required String ownerName,
    required String vin,
  }) async {
    final response = await _api.post('/v1/me/profile', {
      'name': name,
      'email': email,
      'phone': phone,
      'registrationNumber': registrationNumber,
      'model': model,
      'ownerName': ownerName,
      'vin': vin,
    });
    _notifyChanged();
    return _vehicle(_map(response)['vehicle']);
  }

  Future<void> updateUserProfile({
    required String uid,
    String? name,
    String? phone,
    String? city,
    DateTime? dateOfBirth,
    String? preferredDrivingMode,
    String? preferredChargingMode,
    String? notificationPreference,
    String? distanceUnit,
    bool? notificationsEnabled,
    bool? locationEnabled,
  }) async {
    if (name != null && name.trim().isEmpty) {
      throw ArgumentError('Name cannot be empty.');
    }
    await _api.patch('/v1/me', {
      if (name != null) 'name': name.trim(),
      if (phone != null) 'phone': phone.trim(),
      if (city != null) 'city': city.trim(),
      if (dateOfBirth != null) 'dateOfBirth': _utc(dateOfBirth),
      if (preferredDrivingMode != null)
        'preferredDrivingMode': preferredDrivingMode.trim(),
      if (preferredChargingMode != null)
        'preferredChargingMode': preferredChargingMode.trim(),
      if (notificationPreference != null)
        'notificationPreference': notificationPreference.trim(),
      if (distanceUnit != null) 'distanceUnit': distanceUnit.trim(),
      'notificationsEnabled': ?notificationsEnabled,
      'locationEnabled': ?locationEnabled,
    });
    _notifyChanged();
  }

  /// Uploads a JPEG or PNG profile photo (at most 300 KB).
  Future<void> uploadProfilePhoto({
    required String contentType,
    required Uint8List bytes,
  }) async {
    await _api.put('/v1/me/photo', {
      'contentType': contentType,
      'base64': base64Encode(bytes),
    });
    _notifyChanged();
  }

  /// The signed-in user's profile photo, or null if none was uploaded.
  Future<Uint8List?> getProfilePhoto() => _api.getBytes('/v1/me/photo');

  // --------------------------------------------------------------- vehicles

  Future<Vehicle> linkVerifiedVehicle({
    required String uid,
    required String registrationNumber,
    required String model,
    required String ownerName,
    required String vin,
  }) async {
    final response = await _api.post('/v1/me/vehicles', {
      'registrationNumber': registrationNumber,
      'model': model,
      'ownerName': ownerName,
      'vin': vin,
    });
    _notifyChanged();
    return _vehicle(_map(response)['vehicle']);
  }

  Future<Vehicle?> verifyConnectedVehicleDetails({
    required String uid,
    required String registrationNumber,
    required String model,
    required String ownerName,
    required String vin,
  }) async {
    final response = await _api.post('/v1/vehicles/verify', {
      'registrationNumber': registrationNumber,
      'model': model,
      'ownerName': ownerName,
      'vin': vin,
    });
    return _vehicleOrNull(_map(response)['vehicle']);
  }

  Future<void> setConnectedVehicle({
    required String uid,
    required String vehicleId,
  }) async {
    final normalized = vehicleId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(vehicleId, 'vehicleId', 'Cannot be empty.');
    }
    await _api.put('/v1/me/connected-vehicle', {'vehicleId': normalized});
    _notifyChanged();
  }

  Future<Object?> _connectedVehicleRaw() async =>
      _map(await _api.get('/v1/me/connected-vehicle'))['vehicle'];

  Future<Vehicle?> getCurrentUserVehicle(String uid) async =>
      _vehicleOrNull(await _connectedVehicleRaw());

  Stream<Vehicle?> watchConnectedVehicle(String uid) =>
      _watch(_connectedVehicleRaw, _vehicleOrNull);

  Stream<List<Vehicle>> watchLinkedVehicles(String uid) => _watch(
    () async => _map(await _api.get('/v1/me/vehicles'))['vehicles'],
    (raw) => List.unmodifiable(_list(raw).map(_vehicle)),
  );

  Future<Object?> _vehicleRaw(String vehicleId) async {
    try {
      return await _api.get(_vehiclePath(vehicleId));
    } on ApiException catch (error) {
      if (error.isNotFound) return null;
      rethrow;
    }
  }

  /// The vehicle record if it is active, otherwise null.
  Future<Vehicle?> getVehicleById(String vehicleId) async {
    final vehicle = _vehicleOrNull(await _vehicleRaw(vehicleId));
    return vehicle?.isActive == true ? vehicle : null;
  }

  /// The vehicle record, active or not.
  Future<Vehicle?> getVehicleRecordById(String vehicleId) async =>
      _vehicleOrNull(await _vehicleRaw(vehicleId));

  Stream<Vehicle?> watchVehicleById(String vehicleId) =>
      _watch(() => _vehicleRaw(vehicleId), _vehicleOrNull);

  Future<Vehicle> updateVehicleConfiguration({
    required String vehicleId,
    required double maximumRangeKm,
    required double? batteryCapacityKwh,
    required String connectorType,
  }) async {
    if (!maximumRangeKm.isFinite || maximumRangeKm <= 0) {
      throw ArgumentError.value(
        maximumRangeKm,
        'maximumRangeKm',
        'Must be a positive finite value.',
      );
    }
    if (batteryCapacityKwh != null &&
        (!batteryCapacityKwh.isFinite || batteryCapacityKwh <= 0)) {
      throw ArgumentError.value(
        batteryCapacityKwh,
        'batteryCapacityKwh',
        'Must be a positive finite value when provided.',
      );
    }
    final response = await _api
        .patch('${_vehiclePath(vehicleId)}/configuration', {
          'maximumRangeKm': maximumRangeKm,
          'batteryCapacityKwh': ?batteryCapacityKwh,
          'connectorType': connectorType.trim(),
        });
    _notifyChanged();
    return _vehicle(response);
  }

  // ------------------------------------------------------------ maintenance

  Stream<List<VehicleMaintenanceRecord>> watchVehicleMaintenanceRecords(
    String vehicleId,
  ) => _watch(
    () async => _map(
      await _api.get('${_vehiclePath(vehicleId)}/maintenance'),
    )['records'],
    (raw) => _list(raw)
        .map(
          (map) => VehicleMaintenanceRecord.fromMap(
            map,
            id: map['id'] as String? ?? '',
          ),
        )
        .toList(growable: false),
  );

  Future<void> addVehicleMaintenanceRecord({
    required String vehicleId,
    required String serviceType,
    required String category,
    required DateTime serviceDate,
    DateTime? nextServiceDate,
    double? odometerKm,
    double? cost,
    String? serviceCenter,
    String? notes,
  }) async {
    if (serviceType.trim().isEmpty) {
      throw ArgumentError('Vehicle and service type are required.');
    }
    if (odometerKm != null && (!odometerKm.isFinite || odometerKm < 0)) {
      throw ArgumentError.value(odometerKm, 'odometerKm');
    }
    if (cost != null && (!cost.isFinite || cost < 0)) {
      throw ArgumentError.value(cost, 'cost');
    }
    await _api.post('${_vehiclePath(vehicleId)}/maintenance', {
      'serviceType': serviceType.trim(),
      'category': category,
      'serviceDate': _utc(serviceDate),
      'nextServiceDate': nextServiceDate == null ? null : _utc(nextServiceDate),
      'odometerKm': odometerKm,
      // Money goes to the server with at most two decimals.
      'cost': cost == null ? null : (cost * 100).round() / 100,
      'serviceCenter': serviceCenter?.trim() ?? '',
      'notes': notes?.trim() ?? '',
    });
    _notifyChanged();
  }

  // ------------------------------------------------------ controls settings

  Future<VehicleControlsPreferences> getVehicleControlsPreferences({
    required String uid,
    required String vehicleId,
  }) async {
    final response = _map(
      await _api.get('${_vehiclePath(vehicleId)}/controls-preferences'),
    );
    return VehicleControlsPreferences.fromMap(response['preferences']);
  }

  Future<void> saveVehicleControlsPreferences({
    required String uid,
    required String vehicleId,
    required VehicleControlsPreferences preferences,
  }) async {
    await _api.put('${_vehiclePath(vehicleId)}/controls-preferences', {
      'preferences': preferences.toMap(),
    });
    _notifyChanged();
  }

  // ---------------------------------------------------------- charging card

  Future<Object?> _cardRaw(String vehicleId) async =>
      _map(await _api.get('${_vehiclePath(vehicleId)}/charging-card'))['card'];

  Future<ChargingCard?> getChargingCard(
    String uid, {
    required String vehicleId,
  }) async => _cardOrNull(await _cardRaw(vehicleId));

  Stream<ChargingCard?> watchChargingCard(
    String uid, {
    required String vehicleId,
    String? vehicleModel,
    String? vehicleRegistration,
  }) => _watch(() => _cardRaw(vehicleId), _cardOrNull);

  Stream<List<ChargingTransaction>> watchChargingTransactions(
    String uid, {
    required String vehicleId,
  }) => _watch(
    () async => _map(
      await _api.get(
        '${_vehiclePath(vehicleId)}/charging-card/transactions',
        query: {'limit': '50'},
      ),
    )['transactions'],
    (raw) => List.unmodifiable(
      _list(raw).map(
        (map) =>
            ChargingTransaction.fromMap(map, id: map['id'] as String? ?? ''),
      ),
    ),
  );

  static bool _isCardLastFour(String value) =>
      RegExp(r'^[A-Za-z0-9]{4}$').hasMatch(value);

  /// Only the last four characters of a card number ever leave the device.
  Future<ChargingCard> registerChargingCard({
    required String uid,
    required String cardType,
    required String cardLastFour,
    required String cardHolderName,
    required String vehicleId,
    DateTime? expiryDate,
    String currency = 'INR',
  }) async {
    final lastFour = cardLastFour.trim();
    final normalizedCurrency = currency.trim().toUpperCase();
    if (cardType.trim().isEmpty ||
        !_isCardLastFour(lastFour) ||
        cardHolderName.trim().isEmpty ||
        vehicleId.trim().isEmpty ||
        expiryDate == null ||
        normalizedCurrency.length != 3) {
      throw ArgumentError(
        'Complete all charging card fields and use a three-letter currency code.',
      );
    }
    final response = await _api
        .post('${_vehiclePath(vehicleId)}/charging-card', {
          'cardType': cardType.trim(),
          'cardLastFour': lastFour,
          'maskedCardNumber': 'XXXX XXXX XXXX $lastFour',
          'cardHolderName': cardHolderName.trim(),
          'expiryDate': _utc(expiryDate),
          'currency': normalizedCurrency,
        });
    _notifyChanged();
    return _cardOrNull(_map(response)['card'])!;
  }

  Future<ChargingCard> updateChargingCardDetails({
    required String uid,
    required String cardType,
    String? cardLastFour,
    required String cardHolderName,
    required String vehicleId,
    DateTime? expiryDate,
  }) async {
    final lastFour = cardLastFour?.trim() ?? '';
    if (cardType.trim().isEmpty ||
        (lastFour.isNotEmpty && !_isCardLastFour(lastFour)) ||
        cardHolderName.trim().isEmpty ||
        vehicleId.trim().isEmpty ||
        expiryDate == null) {
      throw ArgumentError('Complete all charging card fields.');
    }
    final response = await _api.patch(
      '${_vehiclePath(vehicleId)}/charging-card',
      {
        'cardType': cardType.trim(),
        'cardHolderName': cardHolderName.trim(),
        'expiryDate': _utc(expiryDate),
        if (lastFour.isNotEmpty) ...{
          'cardLastFour': lastFour,
          'maskedCardNumber': 'XXXX XXXX XXXX $lastFour',
        },
      },
    );
    _notifyChanged();
    return _cardOrNull(_map(response)['card'])!;
  }

  Future<Map<String, dynamic>> createPayPalRechargeOrder({
    required String uid,
    required String vehicleId,
    required double amount,
    String currency = 'INR',
  }) async {
    if (!amount.isFinite || amount <= 0) {
      throw ArgumentError('Recharge amount must be greater than zero.');
    }
    if (currency.trim().toUpperCase() != 'INR') {
      throw ArgumentError('PayPal Sandbox top-ups use an INR charging card.');
    }
    return _map(
      await _api.post(
        '${_vehiclePath(vehicleId)}/charging-card/paypal-orders',
        {'amountInr': amount},
      ),
    );
  }

  Future<Map<String, dynamic>> capturePayPalRechargeOrder({
    required String uid,
    required String vehicleId,
    required String orderId,
  }) async {
    final normalizedOrderId = orderId.trim();
    if (normalizedOrderId.isEmpty) {
      throw ArgumentError.value(
        orderId,
        'orderId',
        'A PayPal order ID is required.',
      );
    }
    final response = _map(
      await _api.post(
        '${_vehiclePath(vehicleId)}/charging-card/paypal-orders/'
        '${Uri.encodeComponent(normalizedOrderId)}/capture',
      ),
    );
    _notifyChanged();
    return response;
  }

  /// The payment receipt PDF for a verified PayPal recharge, with its file
  /// name. The backend creates the receipt on first request, so this is also
  /// the safe retry when creating it right after capture failed; it never
  /// repeats the payment.
  Future<(String, Uint8List)> downloadRechargeInvoice({
    required String vehicleId,
    required String transactionId,
  }) async {
    final path =
        '${_vehiclePath(vehicleId)}/charging-card/transactions/'
        '${Uri.encodeComponent(transactionId.trim())}/invoice';
    final invoice = _map(_map(await _api.get(path))['invoice']);
    final bytes = await _api.getBytes('$path.pdf');
    if (bytes == null ||
        bytes.length < 5 ||
        String.fromCharCodes(bytes.take(5)) != '%PDF-') {
      throw const ApiException(
        404,
        'invoice_not_found',
        'The receipt could not be downloaded. Please try again.',
      );
    }
    final number = invoice['invoiceNumber'];
    return (
      number is String && RegExp(r'^[A-Z0-9-]{1,40}$').hasMatch(number)
          ? '$number.pdf'
          : 'EV-Smart-Companion-receipt.pdf',
      bytes,
    );
  }

  /// Debits only a server-confirmed charging session; the client cannot submit
  /// the amount or station details used by the backend.
  Future<ChargingCard> debitChargingCardAfterConfirmedSession({
    required String uid,
    required String sessionId,
  }) async {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) {
      throw ArgumentError(
        'A confirmed charging-session reference is required.',
      );
    }
    final response = _map(
      await _api.post(
        '/v1/charging-sessions/${Uri.encodeComponent(normalizedSessionId)}/debit',
      ),
    );
    _notifyChanged();
    final vehicleId = response['vehicleId'];
    if (vehicleId is! String || vehicleId.isEmpty) {
      throw StateError(
        'The charging-session service did not identify the charged vehicle.',
      );
    }
    final card = await getChargingCard(uid, vehicleId: vehicleId);
    if (card == null) {
      throw StateError(
        'The charging session was processed, but the updated card could not be loaded.',
      );
    }
    return card;
  }
}
