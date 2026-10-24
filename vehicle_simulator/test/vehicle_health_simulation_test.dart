import 'package:flutter_test/flutter_test.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';
import 'package:vehicle_simulator/vehicle_health_simulation.dart';

const _parked = VehicleControlState(health: VehicleHealthState());

void main() {
  group('health scenarios', () {
    test('motor overheating sets 112 °C and holds while driving', () {
      final simulator = VehicleHealthSimulator();
      var state = simulator.applyScenario(
        HealthScenario.motorOverheating,
        _parked.copyWith(speedKph: 30, vehicleOn: true),
      );
      expect(state.health!.motor.temperatureC, 112);
      expect(state.health!.motor.status, MotorOperatingStatus.overheating);

      for (var second = 0; second < 30; second++) {
        state = state.copyWith(health: simulator.tick(state));
      }
      expect(state.health!.motor.temperatureC, greaterThan(112));
      expect(state.health!.motor.status, MotorOperatingStatus.overheating);
    });

    test('battery overheating sets 58 °C', () {
      final state = VehicleHealthSimulator().applyScenario(
        HealthScenario.batteryOverheating,
        _parked,
      );
      expect(state.health!.battery.temperatureC, 58);
    });

    test('low tyre pressure affects only the front-left tyre', () {
      final health = VehicleHealthSimulator()
          .applyScenario(HealthScenario.lowTirePressureFrontLeft, _parked)
          .health!;
      expect(health.tire(VehicleDoor.frontLeft).pressurePsi, 24);
      expect(health.tire(VehicleDoor.frontRight).pressurePsi, 35);
      expect(health.tire(VehicleDoor.rearLeft).pressurePsi, 35);
      expect(health.tire(VehicleDoor.rearRight).pressurePsi, 35);
    });

    test('brake pads worn sets front 12 % and rear 18 %', () {
      final brakes = VehicleHealthSimulator()
          .applyScenario(HealthScenario.brakePadsWorn, _parked)
          .health!
          .brakes;
      expect(brakes.frontPadPercent, 12);
      expect(brakes.rearPadPercent, 18);
    });

    test('software update available sets the flag', () {
      final software = VehicleHealthSimulator()
          .applyScenario(HealthScenario.softwareUpdateAvailable, _parked)
          .health!
          .software;
      expect(software.updateAvailable, isTrue);
    });

    test('all healthy clears faults but keeps odometer and cycles', () {
      final simulator = VehicleHealthSimulator();
      var state = _parked.copyWith(
        health: const VehicleHealthState(
          odometerKm: 20000,
          battery: BatteryHealthState(chargeCycles: 400),
        ),
      );
      for (final scenario in HealthScenario.values) {
        if (scenario != HealthScenario.allHealthy) {
          state = simulator.applyScenario(scenario, state);
        }
      }
      state = simulator.applyScenario(HealthScenario.allHealthy, state);
      final health = state.health!;

      expect(simulator.motorOverheatFault, isFalse);
      expect(simulator.batteryOverheatFault, isFalse);
      expect(health.motor.temperatureC, 25);
      expect(health.motor.status, MotorOperatingStatus.off);
      expect(health.battery.temperatureC, 25);
      expect(health.tire(VehicleDoor.frontLeft).pressurePsi, 35);
      expect(health.brakes.frontPadPercent, 78);
      expect(health.software.updateAvailable, isFalse);
      expect(health.odometerKm, 20000);
      expect(health.battery.chargeCycles, 400);
    });

    test('restore normal state resets every value and fault', () {
      final simulator = VehicleHealthSimulator();
      simulator.applyScenario(HealthScenario.motorOverheating, _parked);
      final state = simulator.reset();
      expect(simulator.motorOverheatFault, isFalse);
      expect(state.health!.motor.temperatureC, 25);
      expect(state.speedKph, 0);
    });
  });

  group('derived values', () {
    test('driving raises RPM and motor temperature and adds distance', () {
      final simulator = VehicleHealthSimulator();
      var state = _parked.copyWith(speedKph: 60, vehicleOn: true);
      for (var second = 0; second < 60; second++) {
        state = state.copyWith(health: simulator.tick(state));
      }
      final health = state.health!;
      expect(health.motor.rpm, 4200);
      expect(health.motor.status, MotorOperatingStatus.running);
      expect(health.motor.temperatureC, greaterThan(45));
      expect(health.odometerKm, closeTo(18451, 0.001));
      expect(health.brakes.frontPadPercent, lessThan(78));
    });

    test('a parked vehicle cools down and reports the motor off', () {
      final simulator = VehicleHealthSimulator();
      var state = _parked.copyWith(
        health: const VehicleHealthState(
          motor: MotorHealthState(temperatureC: 80),
        ),
      );
      for (var second = 0; second < 60; second++) {
        state = state.copyWith(health: simulator.tick(state));
      }
      expect(state.health!.motor.temperatureC, lessThan(30));
      expect(state.health!.motor.rpm, 0);
      expect(state.health!.motor.status, MotorOperatingStatus.off);
    });

    test('charging warms the battery and follows the voltage', () {
      final simulator = VehicleHealthSimulator();
      var state = _parked.copyWith(
        chargingConnected: true,
        chargingPowerKw: 7.2,
        batteryPercent: 50,
      );
      for (var second = 0; second < 60; second++) {
        state = state.copyWith(health: simulator.tick(state));
      }
      expect(state.health!.battery.temperatureC, greaterThan(32));
      expect(state.health!.battery.voltageV, 330 + 50 * 0.9 + 5);
    });

    test('every 100 % charged while charging adds one cycle', () {
      final simulator = VehicleHealthSimulator();
      var state = _parked.copyWith(
        batteryPercent: 0,
        chargingConnected: true,
        chargingPowerKw: 7.2,
      );
      for (var percent = 1; percent <= 100; percent++) {
        state = simulator.recordStateChange(
          state,
          state.copyWith(batteryPercent: percent.toDouble()),
        );
      }
      expect(state.health!.battery.chargeCycles, 313);
    });

    test('raising the battery slider without charging adds no cycles', () {
      final simulator = VehicleHealthSimulator();
      final state = simulator.recordStateChange(
        _parked.copyWith(batteryPercent: 0),
        _parked.copyWith(batteryPercent: 100),
      );
      expect(state.health!.battery.chargeCycles, 312);
    });

    test('manual mode leaves values unchanged', () {
      final simulator = VehicleHealthSimulator()..autoUpdate = false;
      final state = _parked.copyWith(speedKph: 100, vehicleOn: true);
      expect(simulator.tick(state).motor.temperatureC, 25);
      expect(simulator.tick(state).odometerKm, 18450);
    });
  });
}
