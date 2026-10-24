import 'package:flutter_application_2/models/vehicle_health.dart';
import 'package:flutter_application_2/models/vehicle_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

VehicleHealthData _fromHealth(VehicleHealthState health) =>
    VehicleHealthData.fromTelemetry(
      VehicleData.fromSnapshot(
        VehicleStateSnapshot(
          vehicleId: 'EV001',
          sequence: 1,
          timestampMillis: 1,
          state: VehicleControlState(health: health),
        ),
      )!,
    );

void main() {
  group('live BLE health', () {
    test('a snapshot without health reports nothing', () {
      expect(
        VehicleData.fromSnapshot(
          const VehicleStateSnapshot(
            vehicleId: 'EV001',
            sequence: 1,
            timestampMillis: 1,
            state: VehicleControlState(),
          ),
        ),
        isNull,
      );
      expect(VehicleData.fromSnapshot(null), isNull);
    });

    test('maps every reported field and leaves the rest unreported', () {
      final telemetry = VehicleData.fromSnapshot(
        const VehicleStateSnapshot(
          vehicleId: 'EV001',
          sequence: 1,
          timestampMillis: 1,
          state: VehicleControlState(
            batteryPercent: 64,
            health: VehicleHealthState(odometerKm: 18500),
          ),
        ),
      )!;

      expect(telemetry.battery, 64);
      expect(telemetry.batteryHealth, 94);
      expect(telemetry.batteryTemperatureC, 25);
      expect(telemetry.batteryCapacityKwh, 60);
      expect(telemetry.chargingCycles, 312);
      expect(telemetry.batteryAgeMonths, 26);
      expect(telemetry.batteryVoltageV, 397.5);
      expect(telemetry.motorHealth, 96);
      expect(telemetry.motorRpm, 0);
      expect(telemetry.motorStatus, 'Off');
      expect(telemetry.tirePressureFlPsi, 35);
      expect(telemetry.tireTreadRrPercent, 85);
      expect(telemetry.frontBrakePadLifePercent, 78);
      expect(telemetry.brakeHealth, 78);
      expect(telemetry.brakeFluidStatus, 'OK');
      expect(telemetry.vehicleSoftwareVersion, '4.2.1');
      expect(telemetry.softwareUpdateAvailable, isFalse);
      expect(telemetry.odometerKm, 18500);
      expect(telemetry.infotainmentVersion, isNull);
      expect(telemetry.tireTemperatureFlC, isNull);
      expect(telemetry.ecoScore, isNull);
    });

    test('default simulator values are all good', () {
      final health = _fromHealth(const VehicleHealthState());
      expect(
        health.components.map((component) => component.status),
        everyElement(VehicleHealthStatus.healthy),
      );
      expect(health.overallStatus, 'GOOD HEALTH');
      expect(
        health.component(VehicleHealthComponent.software).displayValue,
        'v4.2.1',
      );
    });

    test('each scenario turns its component warning or critical', () {
      final overheating = _fromHealth(
        const VehicleHealthState(motor: MotorHealthState(temperatureC: 112)),
      );
      expect(
        overheating.component(VehicleHealthComponent.motor).status,
        VehicleHealthStatus.critical,
      );
      expect(overheating.overallStatus, 'REQUIRES SERVICE');

      final hotBattery = _fromHealth(
        const VehicleHealthState(
          battery: BatteryHealthState(temperatureC: 48),
        ),
      );
      expect(
        hotBattery.component(VehicleHealthComponent.battery).status,
        VehicleHealthStatus.attention,
      );

      final lowTire = _fromHealth(
        const VehicleHealthState(
          tires: {
            VehicleDoor.frontLeft: TireState(pressurePsi: 24),
            VehicleDoor.frontRight: TireState(),
            VehicleDoor.rearLeft: TireState(),
            VehicleDoor.rearRight: TireState(),
          },
        ),
      );
      expect(
        lowTire.component(VehicleHealthComponent.tires).status,
        VehicleHealthStatus.critical,
      );

      final worn = _fromHealth(
        const VehicleHealthState(
          brakes: BrakeHealthState(frontPadPercent: 12, rearPadPercent: 18),
        ),
      );
      expect(worn.component(VehicleHealthComponent.brakes).score, 12);
      expect(
        worn.component(VehicleHealthComponent.brakes).status,
        VehicleHealthStatus.critical,
      );

      // Half-worn pads are normal wear, not a critical score.
      final halfWorn = _fromHealth(
        const VehicleHealthState(
          brakes: BrakeHealthState(frontPadPercent: 50, rearPadPercent: 55),
        ),
      );
      expect(
        halfWorn.component(VehicleHealthComponent.brakes).status,
        VehicleHealthStatus.healthy,
      );

      final update = _fromHealth(
        const VehicleHealthState(
          software: SoftwareState(updateAvailable: true),
        ),
      );
      expect(
        update.component(VehicleHealthComponent.software).status,
        VehicleHealthStatus.attention,
      );
    });
  });

  test(
    'averages reported component health without inventing missing scores',
    () {
      const telemetry = VehicleData(
        battery: 72,
        range: 300,
        batteryHealth: 90,
        healthScore: 87,
        isCharging: false,
        motorHealth: 80,
        brakeHealth: 70,
        softwareHealth: 100,
      );

      final health = VehicleHealthData.fromTelemetry(telemetry);

      expect(health.score, closeTo(85, 0.01));
      expect(health.component(VehicleHealthComponent.tires).score, isNull);
      expect(
        health.component(VehicleHealthComponent.tires).status,
        VehicleHealthStatus.unavailable,
      );
    },
  );

  test('derives tire status and tips only from reported values', () {
    const telemetry = VehicleData(
      battery: 72,
      range: 300,
      batteryHealth: 90,
      healthScore: 87,
      isCharging: false,
      tirePressureFlPsi: 35,
      tirePressureFrPsi: 29,
      ecoScore: 65,
      hardBrakingEvents: 2,
    );

    final health = VehicleHealthData.fromTelemetry(telemetry);

    expect(health.component(VehicleHealthComponent.tires).score, 76);
    expect(
      health.component(VehicleHealthComponent.tires).status,
      VehicleHealthStatus.attention,
    );
    expect(health.drivingTips, hasLength(2));
    expect(health.drivingTips.join(' '), contains('Gentler acceleration'));
  });

  test('preserves a reported zero as a critical component score', () {
    const telemetry = VehicleData(
      battery: 72,
      range: 300,
      batteryHealth: 0,
      healthScore: 87,
      isCharging: false,
    );

    final health = VehicleHealthData.fromTelemetry(telemetry);

    expect(health.score, 0);
    expect(
      health.component(VehicleHealthComponent.battery).status,
      VehicleHealthStatus.critical,
    );
  });
}
