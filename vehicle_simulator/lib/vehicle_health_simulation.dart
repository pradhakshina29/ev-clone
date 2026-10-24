import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

/// Demo health scenarios offered by the simulator.
enum HealthScenario {
  motorOverheating('Motor overheating'),
  batteryOverheating('Battery overheating'),
  lowTirePressureFrontLeft('Low tyre pressure (front-left)'),
  brakePadsWorn('Brake pads worn'),
  softwareUpdateAvailable('Software update available'),
  allHealthy('All healthy');

  const HealthScenario(this.label);

  final String label;
}

/// Derives component health from the simulator's own driving and charging
/// state. Values change only through [tick], [recordStateChange], scenarios or
/// the manual controls; nothing is random.
class VehicleHealthSimulator {
  static const ambientC = 25.0;
  static const motorOverheatC = 110.0;
  static const _motorFaultTargetC = 115.0;
  static const _batteryFaultTargetC = 60.0;
  // RPM per km/h for a single-speed EV drivetrain (≈8.5:1, 2 m wheel).
  static const _rpmPerKph = 70.0;
  // Pad life used per driven km (≈50,000 km from new).
  static const _padWearPercentPerKm = 0.002;

  bool autoUpdate = true;
  bool motorOverheatFault = false;
  bool batteryOverheatFault = false;
  double _chargedPercent = 0;

  /// Advances temperatures, RPM, voltage, odometer and pad wear by [seconds].
  VehicleHealthState tick(VehicleControlState state, {double seconds = 1}) {
    final health = state.health ?? const VehicleHealthState();
    if (!autoUpdate) return health;
    final speed = state.speedKph;

    final motorTarget = motorOverheatFault
        ? _motorFaultTargetC
        : ambientC + 0.35 * speed + (state.vehicleOn ? 5 : 0);
    final motorTemp = _approach(
      health.motor.temperatureC,
      motorTarget,
      0.08 * seconds,
    );
    final batteryTarget = batteryOverheatFault
        ? _batteryFaultTargetC
        : ambientC + 1.2 * state.chargingPowerKw + 0.08 * speed;
    final batteryTemp = _approach(
      health.battery.temperatureC,
      batteryTarget,
      0.05 * seconds,
    );
    final distanceKm = speed / 3600 * seconds;
    final padWear = distanceKm * _padWearPercentPerKm;

    return health.copyWith(
      battery: health.battery.copyWith(
        temperatureC: batteryTemp,
        voltageV: voltageFor(state),
      ),
      motor: health.motor.copyWith(
        temperatureC: motorTemp,
        rpm: (speed * _rpmPerKph).round().clamp(0, 20000),
        status: motorStatusFor(state, motorTemp),
      ),
      brakes: health.brakes.copyWith(
        frontPadPercent: (health.brakes.frontPadPercent - padWear)
            .clamp(0, 100)
            .toDouble(),
        rearPadPercent: (health.brakes.rearPadPercent - padWear * 0.7)
            .clamp(0, 100)
            .toDouble(),
      ),
      odometerKm: health.odometerKm + distanceKm,
    );
  }

  /// Counts one charge cycle for every 100 % of charge added while charging.
  VehicleControlState recordStateChange(
    VehicleControlState previous,
    VehicleControlState next,
  ) {
    final health = next.health;
    if (health == null) return next;
    final added = next.batteryPercent - previous.batteryPercent;
    if (added <= 0 || !(previous.chargingConnected || next.chargingConnected)) {
      return next;
    }
    _chargedPercent += added;
    var cycles = health.battery.chargeCycles;
    while (_chargedPercent >= 100) {
      _chargedPercent -= 100;
      cycles++;
    }
    if (cycles == health.battery.chargeCycles) return next;
    return next.copyWith(
      health: health.copyWith(
        battery: health.battery.copyWith(chargeCycles: cycles),
      ),
    );
  }

  /// Applies [scenario] to [state]; faults stay active until "All healthy".
  VehicleControlState applyScenario(
    HealthScenario scenario,
    VehicleControlState state,
  ) {
    final health = state.health ?? const VehicleHealthState();
    final updated = switch (scenario) {
      HealthScenario.motorOverheating => () {
        motorOverheatFault = true;
        return health.copyWith(
          motor: health.motor.copyWith(
            temperatureC: 112,
            status: MotorOperatingStatus.overheating,
          ),
        );
      }(),
      HealthScenario.batteryOverheating => () {
        batteryOverheatFault = true;
        return health.copyWith(
          battery: health.battery.copyWith(temperatureC: 58),
        );
      }(),
      HealthScenario.lowTirePressureFrontLeft => health.copyWith(
        tires: {
          ...health.tires,
          VehicleDoor.frontLeft: health
              .tire(VehicleDoor.frontLeft)
              .copyWith(pressurePsi: 24),
        },
      ),
      HealthScenario.brakePadsWorn => health.copyWith(
        brakes: health.brakes.copyWith(frontPadPercent: 12, rearPadPercent: 18),
      ),
      HealthScenario.softwareUpdateAvailable => health.copyWith(
        software: health.software.copyWith(updateAvailable: true),
      ),
      HealthScenario.allHealthy => _healthy(state, health),
    };
    return state.copyWith(health: updated);
  }

  /// Clears faults and returns the default state used by "Restore Normal State".
  VehicleControlState reset() {
    motorOverheatFault = false;
    batteryOverheatFault = false;
    _chargedPercent = 0;
    return const VehicleControlState(health: VehicleHealthState());
  }

  VehicleHealthState _healthy(
    VehicleControlState state,
    VehicleHealthState health,
  ) {
    motorOverheatFault = false;
    batteryOverheatFault = false;
    const normal = VehicleHealthState();
    final motorTemp = ambientC + 0.35 * state.speedKph;
    // Keeps accumulated history (odometer, cycles, age, capacity, version).
    return health.copyWith(
      battery: health.battery.copyWith(
        stateOfHealthPercent: normal.battery.stateOfHealthPercent,
        temperatureC: ambientC,
      ),
      motor: health.motor.copyWith(
        healthPercent: normal.motor.healthPercent,
        temperatureC: motorTemp,
        efficiencyPercent: normal.motor.efficiencyPercent,
        status: motorStatusFor(state, motorTemp),
      ),
      tires: normal.tires,
      brakes: normal.brakes,
      software: health.software.copyWith(updateAvailable: false),
    );
  }

  static MotorOperatingStatus motorStatusFor(
    VehicleControlState state,
    double motorTemperatureC,
  ) {
    if (motorTemperatureC >= motorOverheatC) {
      return MotorOperatingStatus.overheating;
    }
    if (state.speedKph > 0) return MotorOperatingStatus.running;
    return state.vehicleOn
        ? MotorOperatingStatus.idle
        : MotorOperatingStatus.off;
  }

  /// A 96-cell pack: about 330 V empty to 420 V full, slightly higher on charge.
  static double voltageFor(VehicleControlState state) =>
      330 + state.batteryPercent * 0.9 + (state.chargingConnected ? 5 : 0);

  static double _approach(double current, double target, double fraction) =>
      current + (target - current) * fraction.clamp(0, 1);
}
