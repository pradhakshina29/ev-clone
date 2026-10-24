import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

class VehicleData {
  const VehicleData({
    required this.battery,
    required this.range,
    required this.batteryHealth,
    required this.healthScore,
    required this.isCharging,
    this.updatedAt,
    this.batteryTemperatureC,
    this.batteryCapacityKwh,
    this.batteryAgeMonths,
    this.chargingCycles,
    this.motorHealth,
    this.motorTemperatureC,
    this.motorEfficiencyPercent,
    this.motorLoadPercent,
    this.motorRpm,
    this.motorOperatingHours,
    this.rangeImpact,
    this.frontBrakePadLifePercent,
    this.rearBrakePadLifePercent,
    this.brakeFluidStatus,
    this.brakeTemperatureC,
    this.vehicleSoftwareVersion,
    this.infotainmentVersion,
    this.firmwareVersion,
    this.securityStatus,
    this.brakeHealth,
    this.hardBrakingEvents,
    this.tripsAnalyzed,
    this.tirePressureTrendPsiPerWeek,
    this.tirePressureFlPsi,
    this.tirePressureFrPsi,
    this.tirePressureRlPsi,
    this.tirePressureRrPsi,
    this.tireTemperatureFlC,
    this.tireTemperatureFrC,
    this.tireTemperatureRlC,
    this.tireTemperatureRrC,
    this.softwareHealth,
    this.dcFastChargePercentage,
    this.ecoScore,
    this.ecoStreakDays,
    this.efficiencyKmPerKwh,
    this.regenerativeEnergyKwh,
    this.lastTripDistanceKm,
    this.lastTripEnergyKwh,
    this.odometerKm,
    this.batteryVoltageV,
    this.motorStatus,
    this.tireTreadFlPercent,
    this.tireTreadFrPercent,
    this.tireTreadRlPercent,
    this.tireTreadRrPercent,
    this.softwareUpdateAvailable,
  });

  final double battery;
  final double range;
  final double batteryHealth;
  final int healthScore;
  final bool isCharging;
  final DateTime? updatedAt;
  final double? batteryTemperatureC;
  final double? motorEfficiencyPercent;
  final double? motorLoadPercent;
  final int? motorRpm;
  final double? motorOperatingHours;
  final Map<String, double>? rangeImpact;
  final double? frontBrakePadLifePercent;
  final double? rearBrakePadLifePercent;
  final String? brakeFluidStatus;
  final double? brakeTemperatureC;
  final String? vehicleSoftwareVersion;
  final String? infotainmentVersion;
  final String? firmwareVersion;
  final String? securityStatus;

  final double? batteryCapacityKwh;
  final int? batteryAgeMonths;
  final int? chargingCycles;
  final double? motorHealth;
  final double? motorTemperatureC;
  final double? brakeHealth;
  final int? hardBrakingEvents;
  final int? tripsAnalyzed;
  final double? tirePressureTrendPsiPerWeek;
  final double? tirePressureFlPsi;
  final double? tirePressureFrPsi;
  final double? tirePressureRlPsi;
  final double? tirePressureRrPsi;
  final double? tireTemperatureFlC;
  final double? tireTemperatureFrC;
  final double? tireTemperatureRlC;
  final double? tireTemperatureRrC;
  final double? softwareHealth;
  final double? dcFastChargePercentage;
  final int? ecoScore;
  final int? ecoStreakDays;
  final double? efficiencyKmPerKwh;
  final double? regenerativeEnergyKwh;
  final double? lastTripDistanceKm;
  final double? lastTripEnergyKwh;
  final double? odometerKm;
  final double? batteryVoltageV;
  final String? motorStatus;
  final double? tireTreadFlPercent;
  final double? tireTreadFrPercent;
  final double? tireTreadRlPercent;
  final double? tireTreadRrPercent;
  final bool? softwareUpdateAvailable;

  /// Live values from a BLE snapshot. Returns null when the snapshot has no
  /// health section, so every health field stays "Not reported". Only fields
  /// the simulator sends are filled; the rest stay null.
  static VehicleData? fromSnapshot(VehicleStateSnapshot? snapshot) {
    final state = snapshot?.state;
    final health = state?.health;
    if (state == null || health == null) return null;
    final brakes = health.brakes;
    final software = health.software;
    return VehicleData(
      battery: state.batteryPercent,
      range: state.rangeKm,
      batteryHealth: health.battery.stateOfHealthPercent,
      healthScore: 0,
      isCharging: state.chargingConnected,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(snapshot!.timestampMillis),
      batteryTemperatureC: health.battery.temperatureC,
      batteryCapacityKwh: health.battery.capacityKwh,
      batteryAgeMonths: health.battery.ageMonths,
      chargingCycles: health.battery.chargeCycles,
      batteryVoltageV: health.battery.voltageV,
      motorHealth: health.motor.healthPercent,
      motorTemperatureC: health.motor.temperatureC,
      motorEfficiencyPercent: health.motor.efficiencyPercent,
      motorRpm: health.motor.rpm,
      motorStatus: switch (health.motor.status) {
        MotorOperatingStatus.off => 'Off',
        MotorOperatingStatus.idle => 'Idle',
        MotorOperatingStatus.running => 'Running',
        MotorOperatingStatus.overheating => 'Overheating',
      },
      tirePressureFlPsi: health.tire(VehicleDoor.frontLeft).pressurePsi,
      tirePressureFrPsi: health.tire(VehicleDoor.frontRight).pressurePsi,
      tirePressureRlPsi: health.tire(VehicleDoor.rearLeft).pressurePsi,
      tirePressureRrPsi: health.tire(VehicleDoor.rearRight).pressurePsi,
      tireTreadFlPercent: health.tire(VehicleDoor.frontLeft).treadPercent,
      tireTreadFrPercent: health.tire(VehicleDoor.frontRight).treadPercent,
      tireTreadRlPercent: health.tire(VehicleDoor.rearLeft).treadPercent,
      tireTreadRrPercent: health.tire(VehicleDoor.rearRight).treadPercent,
      frontBrakePadLifePercent: brakes.frontPadPercent,
      rearBrakePadLifePercent: brakes.rearPadPercent,
      // The brake score is the more worn of the two pad sets.
      brakeHealth: brakes.frontPadPercent < brakes.rearPadPercent
          ? brakes.frontPadPercent
          : brakes.rearPadPercent,
      brakeFluidStatus: switch (brakes.fluidStatus) {
        BrakeFluidStatus.ok => 'OK',
        BrakeFluidStatus.low => 'Low',
        BrakeFluidStatus.replace => 'Replace',
      },
      vehicleSoftwareVersion: software.version,
      softwareUpdateAvailable: software.updateAvailable,
      odometerKm: health.odometerKm,
    );
  }

  factory VehicleData.fromMap(Map<String, dynamic> map) {
    return VehicleData(
      battery: _number(map['battery'] ?? map['batteryPercentage']),
      range: _number(map['range']),
      batteryHealth: _number(map['batteryHealth']),
      healthScore: _integer(map['healthScore']),
      isCharging: map['isCharging'] is bool && map['isCharging'] as bool,
      updatedAt: _readDate(map['updatedAt']),
      batteryTemperatureC: _optionalNumber(map['batteryTemperatureC']),
      motorEfficiencyPercent: _optionalNumber(map['motorEfficiencyPercent']),
      motorLoadPercent: _optionalNumber(map['motorLoadPercent']),
      motorRpm: _optionalInteger(map['motorRpm']),
      motorOperatingHours: _optionalNumber(map['motorOperatingHours']),
      rangeImpact: _optionalNumberMap(map['rangeImpact']),
      frontBrakePadLifePercent: _optionalNumber(map['frontBrakePadLifePercent']),
      rearBrakePadLifePercent: _optionalNumber(map['rearBrakePadLifePercent']),
      brakeFluidStatus: _optionalText(map['brakeFluidStatus']),
      brakeTemperatureC: _optionalNumber(map['brakeTemperatureC']),
      vehicleSoftwareVersion: _optionalText(map['vehicleSoftwareVersion']),
      infotainmentVersion: _optionalText(map['infotainmentVersion']),
      firmwareVersion: _optionalText(map['firmwareVersion']),
      securityStatus: _optionalText(map['securityStatus']),
      batteryCapacityKwh: _optionalNumber(map['batteryCapacityKwh']),
      batteryAgeMonths: _optionalInteger(map['batteryAgeMonths']),
      chargingCycles: _optionalInteger(map['chargingCycles']),
      motorHealth: _optionalNumber(map['motorHealth']),
      motorTemperatureC: _optionalNumber(map['motorTemperatureC']),
      brakeHealth: _optionalNumber(map['brakeHealth']),
      hardBrakingEvents: _optionalInteger(map['hardBrakingEvents']),
      tripsAnalyzed: _optionalInteger(map['tripsAnalyzed']),
      tirePressureTrendPsiPerWeek: _optionalNumber(
        map['tirePressureTrendPsiPerWeek'],
      ),
      tirePressureFlPsi: _optionalNumber(map['tirePressureFlPsi']),
      tirePressureFrPsi: _optionalNumber(map['tirePressureFrPsi']),
      tirePressureRlPsi: _optionalNumber(map['tirePressureRlPsi']),
      tirePressureRrPsi: _optionalNumber(map['tirePressureRrPsi']),
      tireTemperatureFlC: _optionalNumber(map['tireTemperatureFlC']),
      tireTemperatureFrC: _optionalNumber(map['tireTemperatureFrC']),
      tireTemperatureRlC: _optionalNumber(map['tireTemperatureRlC']),
      tireTemperatureRrC: _optionalNumber(map['tireTemperatureRrC']),
      softwareHealth: _optionalNumber(map['softwareHealth']),
      dcFastChargePercentage: _optionalNumber(map['dcFastChargePercentage']),
      ecoScore: _optionalInteger(map['ecoScore']),
      ecoStreakDays: _optionalInteger(map['ecoStreakDays']),
      efficiencyKmPerKwh: _optionalNumber(map['efficiencyKmPerKwh']),
      regenerativeEnergyKwh: _optionalNumber(map['regenerativeEnergyKwh']),
      lastTripDistanceKm: _optionalNumber(map['lastTripDistanceKm']),
      lastTripEnergyKwh: _optionalNumber(map['lastTripEnergyKwh']),
      odometerKm: _optionalNumber(map['odometerKm'] ?? map['odometer']),
    );
  }

  static double _number(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  static int _integer(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
    static Map<String, double>? _optionalNumberMap(Object? value) {
    if (value is! Map) return null;
    final result = <String, double>{};
    value.forEach((key, raw) {
      final number = _optionalNumber(raw);
      if (key is String && number != null && number >= 0) {
        result[key] = number;
      }
    });
    return result.isEmpty ? null : result;
  }
    static String? _optionalText(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }
  
  static double? _optionalNumber(Object? value) {
    
    final number = switch (value) {
      num() => value.toDouble(),
      String() => double.tryParse(value),
      _ => null,
    };
    return number != null && number.isFinite ? number : null;
  }

  static int? _optionalInteger(Object? value) {
    final number = switch (value) {
      num() => value.toInt(),
      String() => int.tryParse(value),
      _ => null,
    };
    return number;
  }

  static DateTime? _readDate(Object? value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value)?.toLocal();
    return null;
  }
}
