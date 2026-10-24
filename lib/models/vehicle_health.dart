import 'vehicle_telemetry.dart';

enum VehicleHealthComponent { battery, motor, tires, brakes, software }

enum VehicleHealthStatus { healthy, attention, critical, unavailable }

/// Limits shared by the Health page, Maintenance and vehicle alerts.
class HealthThresholds {
  const HealthThresholds._();

  static const batteryTemperatureWarningC = 45.0;
  static const batteryTemperatureCriticalC = 55.0;
  static const motorTemperatureWarningC = 95.0;
  static const motorTemperatureCriticalC = 110.0;
  static const tirePressureLowWarningPsi = 30.0;
  static const tirePressureLowCriticalPsi = 25.0;
  static const tirePressureHighWarningPsi = 42.0;
  static const tireTreadWarningPercent = 20.0;
  static const brakePadWarningPercent = 30.0;
  static const brakePadCriticalPercent = 15.0;

  static VehicleHealthStatus batteryTemperature(double? celsius) =>
      _upper(celsius, batteryTemperatureWarningC, batteryTemperatureCriticalC);

  static VehicleHealthStatus motorTemperature(double? celsius) =>
      _upper(celsius, motorTemperatureWarningC, motorTemperatureCriticalC);

  static VehicleHealthStatus tirePressure(double? psi) {
    if (psi == null || !psi.isFinite) return VehicleHealthStatus.unavailable;
    if (psi < tirePressureLowCriticalPsi) return VehicleHealthStatus.critical;
    if (psi < tirePressureLowWarningPsi || psi > tirePressureHighWarningPsi) {
      return VehicleHealthStatus.attention;
    }
    return VehicleHealthStatus.healthy;
  }

  static VehicleHealthStatus tireTread(double? percent) {
    if (percent == null || !percent.isFinite) {
      return VehicleHealthStatus.unavailable;
    }
    return percent < tireTreadWarningPercent
        ? VehicleHealthStatus.attention
        : VehicleHealthStatus.healthy;
  }

  static VehicleHealthStatus brakePad(double? percent) {
    if (percent == null || !percent.isFinite) {
      return VehicleHealthStatus.unavailable;
    }
    if (percent < brakePadCriticalPercent) return VehicleHealthStatus.critical;
    if (percent < brakePadWarningPercent) return VehicleHealthStatus.attention;
    return VehicleHealthStatus.healthy;
  }

  static VehicleHealthStatus brakeFluid(String? status) =>
      switch (status?.toLowerCase()) {
        null => VehicleHealthStatus.unavailable,
        'replace' => VehicleHealthStatus.critical,
        'low' => VehicleHealthStatus.attention,
        _ => VehicleHealthStatus.healthy,
      };

  static VehicleHealthStatus _upper(
    double? value,
    double warning,
    double critical,
  ) {
    if (value == null || !value.isFinite) {
      return VehicleHealthStatus.unavailable;
    }
    if (value >= critical) return VehicleHealthStatus.critical;
    if (value >= warning) return VehicleHealthStatus.attention;
    return VehicleHealthStatus.healthy;
  }

  /// The most severe of [statuses]; unavailable only when nothing is known.
  static VehicleHealthStatus worst(Iterable<VehicleHealthStatus> statuses) {
    final known = statuses.where(
      (status) => status != VehicleHealthStatus.unavailable,
    );
    if (known.isEmpty) return VehicleHealthStatus.unavailable;
    if (known.contains(VehicleHealthStatus.critical)) {
      return VehicleHealthStatus.critical;
    }
    if (known.contains(VehicleHealthStatus.attention)) {
      return VehicleHealthStatus.attention;
    }
    return VehicleHealthStatus.healthy;
  }
}

class ComponentHealth {
  const ComponentHealth({
    required this.component,
    required this.score,
    required this.status,
    this.valueLabel,
  });

  final VehicleHealthComponent component;
  final double? score;
  final VehicleHealthStatus status;

  /// Shown instead of the score when the component has no percentage,
  /// e.g. the software version.
  final String? valueLabel;

  String get label => switch (component) {
    VehicleHealthComponent.battery => 'Battery',
    VehicleHealthComponent.motor => 'Motor',
    VehicleHealthComponent.tires => 'Tires',
    VehicleHealthComponent.brakes => 'Brakes',
    VehicleHealthComponent.software => 'Software',
  };

  String get displayValue =>
      valueLabel ?? (score == null ? '—' : '${score!.round()}%');

  static VehicleHealthStatus statusFor(double? score) {
    if (score == null || !score.isFinite) return VehicleHealthStatus.unavailable;
    if (score < 60) return VehicleHealthStatus.critical;
    if (score < 80) return VehicleHealthStatus.attention;
    return VehicleHealthStatus.healthy;
  }
}

class VehicleHealthData {
  VehicleHealthData.fromTelemetry(this.telemetry)
    : components = _componentsFrom(telemetry),
      score = _scoreFrom(telemetry);

  final VehicleData telemetry;
  final List<ComponentHealth> components;
  final double score;

  /// The most severe component status, so one critical part is never hidden
  /// by a good average.
  VehicleHealthStatus get overallHealthStatus {
    final status = HealthThresholds.worst(
      components.map((component) => component.status),
    );
    return status == VehicleHealthStatus.unavailable
        ? ComponentHealth.statusFor(score)
        : status;
  }

  String get overallStatus => switch (overallHealthStatus) {
    VehicleHealthStatus.healthy => 'GOOD HEALTH',
    VehicleHealthStatus.attention => 'NEEDS ATTENTION',
    VehicleHealthStatus.critical => 'REQUIRES SERVICE',
    VehicleHealthStatus.unavailable => 'STATUS UNAVAILABLE',
  };

  ComponentHealth component(VehicleHealthComponent component) =>
      components.firstWhere((value) => value.component == component);

  List<String> get drivingTips {
    final tips = <String>[];
    final ecoScore = telemetry.ecoScore;
    if (ecoScore != null && ecoScore < 75) {
      tips.add('Gentler acceleration can help improve your efficiency score.');
    }
    final brakingEvents = telemetry.hardBrakingEvents;
    if (brakingEvents != null && brakingEvents > 0) {
      tips.add(
        'Leave a little more space to reduce hard-braking events and recover more energy.',
      );
    }
    final efficiency = telemetry.efficiencyKmPerKwh;
    if (efficiency != null && efficiency > 0 && efficiency < 5) {
      tips.add(
        'A steady pace can help improve your recent ${efficiency.toStringAsFixed(1)} km/kWh efficiency.',
      );
    }
    final recovered = telemetry.regenerativeEnergyKwh;
    if (recovered != null && recovered > 0) {
      tips.add(
        'You recovered ${recovered.toStringAsFixed(1)} kWh through regenerative braking in the reported period.',
      );
    }
    return tips;
  }

  static List<ComponentHealth> _componentsFrom(VehicleData telemetry) {
    final pressures = [
      telemetry.tirePressureFlPsi,
      telemetry.tirePressureFrPsi,
      telemetry.tirePressureRlPsi,
      telemetry.tirePressureRrPsi,
    ].whereType<double>().toList();
    final treads = [
      telemetry.tireTreadFlPercent,
      telemetry.tireTreadFrPercent,
      telemetry.tireTreadRlPercent,
      telemetry.tireTreadRrPercent,
    ].whereType<double>().toList();
    final pressureScore = pressures.isEmpty
        ? null
        : pressures
                  .map((pressure) {
                    final deviation = (pressure - 35).abs();
                    return (100 - deviation * 8).clamp(0, 100).toDouble();
                  })
                  .reduce((first, second) => first + second) /
              pressures.length;
    final lowestTread = treads.isEmpty
        ? null
        : treads.reduce((first, second) => first < second ? first : second);
    final tireScore = pressureScore == null
        ? null
        : lowestTread != null && lowestTread < pressureScore
        ? lowestTread
        : pressureScore;

    final batteryScore = _boundedScore(telemetry.batteryHealth);
    final motorScore = _boundedScore(telemetry.motorHealth);
    final brakeScore = _boundedScore(telemetry.brakeHealth);
    final softwareScore = _boundedScore(telemetry.softwareHealth);
    final hasPads =
        telemetry.frontBrakePadLifePercent != null ||
        telemetry.rearBrakePadLifePercent != null;
    final updateAvailable = telemetry.softwareUpdateAvailable;
    final softwareVersion = telemetry.vehicleSoftwareVersion;

    return [
      ComponentHealth(
        component: VehicleHealthComponent.battery,
        score: batteryScore,
        status: HealthThresholds.worst([
          ComponentHealth.statusFor(batteryScore),
          HealthThresholds.batteryTemperature(telemetry.batteryTemperatureC),
        ]),
      ),
      ComponentHealth(
        component: VehicleHealthComponent.motor,
        score: motorScore,
        status: HealthThresholds.worst([
          ComponentHealth.statusFor(motorScore),
          HealthThresholds.motorTemperature(telemetry.motorTemperatureC),
        ]),
      ),
      ComponentHealth(
        component: VehicleHealthComponent.tires,
        score: tireScore,
        status: pressures.isEmpty
            ? VehicleHealthStatus.unavailable
            : HealthThresholds.worst([
                ...pressures.map(HealthThresholds.tirePressure),
                ...treads.map(HealthThresholds.tireTread),
              ]),
      ),
      ComponentHealth(
        component: VehicleHealthComponent.brakes,
        score: brakeScore,
        // Pad life is a wear percentage (50 % is fine), so the generic score
        // bands are used only when no pad readings are reported.
        status: hasPads
            ? HealthThresholds.worst([
                HealthThresholds.brakePad(telemetry.frontBrakePadLifePercent),
                HealthThresholds.brakePad(telemetry.rearBrakePadLifePercent),
                HealthThresholds.brakeFluid(telemetry.brakeFluidStatus),
              ])
            : ComponentHealth.statusFor(brakeScore),
      ),
      ComponentHealth(
        component: VehicleHealthComponent.software,
        score: softwareScore,
        status: updateAvailable == null
            ? ComponentHealth.statusFor(softwareScore)
            : updateAvailable
            ? VehicleHealthStatus.attention
            : VehicleHealthStatus.healthy,
        valueLabel: softwareVersion == null || updateAvailable == null
            ? null
            : 'v$softwareVersion',
      ),
    ];
  }

  static double _scoreFrom(VehicleData telemetry) {
    final componentScores = _componentsFrom(
      telemetry,
    ).map((component) => component.score).whereType<double>().toList();
    if (componentScores.isEmpty) return telemetry.healthScore.toDouble();
    return componentScores.reduce((first, second) => first + second) /
        componentScores.length;
  }

  static double? _boundedScore(double? score) {
    if (score == null || !score.isFinite) return null;
    return score.clamp(0, 100).toDouble();
  }
}

class VehicleMaintenanceRecord {
  const VehicleMaintenanceRecord({
    required this.id,
    required this.serviceType,
    required this.status,
    this.category,
    this.serviceDate,
    this.nextServiceDate,
    this.odometerKm,
    this.cost,
    this.serviceCenter,
    this.notes,
  });

  final String id;
  final String serviceType;
  final String status;
  final String? category;
  final DateTime? serviceDate;
  final DateTime? nextServiceDate;
  final double? odometerKm;
  final double? cost;
  final String? serviceCenter;
  final String? notes;

  factory VehicleMaintenanceRecord.fromMap(
    Map<String, dynamic> map, {
    required String id,
  }) => VehicleMaintenanceRecord(
    id: id,
    serviceType: map['serviceType'] as String? ?? 'Service',
    status: map['status'] as String? ?? 'Completed',
    category: map['category'] as String?,
    serviceDate: _date(map['serviceDate']),
    nextServiceDate: _date(map['nextServiceDate']),
    odometerKm: _number(map['odometerKm'] ?? map['odometer']),
    cost: _number(map['cost']),
    serviceCenter: map['serviceCenter'] as String?,
    notes: map['notes'] as String?,
  );

  static double? _number(Object? value) {
    final number = switch (value) {
      num() => value.toDouble(),
      String() => double.tryParse(value),
      _ => null,
    };
    return number != null && number.isFinite ? number : null;
  }

  // The API sends ISO-8601 strings; show them in local time.
  static DateTime? _date(Object? value) => switch (value) {
    DateTime() => value,
    String() => DateTime.tryParse(value)?.toLocal(),
    _ => null,
  };
}
