import 'dart:convert';
import 'dart:typed_data';

const vehicleControlServiceUuid = '8a7e1000-6d8a-4a31-b8d1-1f40cc5a0001';
const vehicleStateCharacteristicUuid = '8a7e1001-6d8a-4a31-b8d1-1f40cc5a0001';
const vehicleCommandCharacteristicUuid = '8a7e1002-6d8a-4a31-b8d1-1f40cc5a0001';
const defaultVehicleSimulatorName = 'EV-Simulator-01';

/// Demo vehicle document IDs created by backend/src/scripts/seed.ts.
const demoVehicleIds = ['EV001', 'EV002', 'EV003', 'EV004', 'EV005', 'EV006'];

/// BLE name the simulator advertises for a vehicle, matching the seed's
/// bluetoothDeviceName: EV001 -> EV-Simulator-01, EV002 -> EV-Simulator-02.
/// IDs outside the EV### pattern use [defaultVehicleSimulatorName].
String vehicleSimulatorNameFor(String vehicleId) {
  final match = RegExp(
    r'^EV0*(\d{1,2})$',
    caseSensitive: false,
  ).firstMatch(vehicleId.trim());
  if (match == null) return defaultVehicleSimulatorName;
  return 'EV-Simulator-${match.group(1)!.padLeft(2, '0')}';
}
const bleFrameHeaderLength = 4;
const bleDefaultFrameLength = 20;
const bleMaximumMessageLength = 4080;

enum VehicleDoor { frontLeft, frontRight, rearLeft, rearRight }

extension VehicleDoorLabel on VehicleDoor {
  String get wireName => switch (this) {
    VehicleDoor.frontLeft => 'frontLeft',
    VehicleDoor.frontRight => 'frontRight',
    VehicleDoor.rearLeft => 'rearLeft',
    VehicleDoor.rearRight => 'rearRight',
  };

  String get label => switch (this) {
    VehicleDoor.frontLeft => 'Front left',
    VehicleDoor.frontRight => 'Front right',
    VehicleDoor.rearLeft => 'Rear left',
    VehicleDoor.rearRight => 'Rear right',
  };
}

class VehicleDoorState {
  const VehicleDoorState({this.open = false, this.locked = true});

  final bool open;
  final bool locked;

  Map<String, Object> toJson() => {'open': open, 'locked': locked};

  static VehicleDoorState fromJson(Object? value) {
    final map = _requireMap(value, 'door');
    return VehicleDoorState(
      open: _requireBool(map['open'], 'door.open'),
      locked: _requireBool(map['locked'], 'door.locked'),
    );
  }
}

enum MotorOperatingStatus { off, idle, running, overheating }

enum BrakeFluidStatus { ok, low, replace }

class BatteryHealthState {
  const BatteryHealthState({
    this.stateOfHealthPercent = 94,
    this.temperatureC = 25,
    this.capacityKwh = 60,
    this.chargeCycles = 312,
    this.ageMonths = 26,
    this.voltageV = 397.5,
  });

  final double stateOfHealthPercent;
  final double temperatureC;
  final double capacityKwh;
  final int chargeCycles;
  final int ageMonths;
  final double voltageV;

  Map<String, Object> toJson() => {
    'stateOfHealthPercent': _round(stateOfHealthPercent),
    'temperatureC': _round(temperatureC),
    'capacityKwh': _round(capacityKwh),
    'chargeCycles': chargeCycles,
    'ageMonths': ageMonths,
    'voltageV': _round(voltageV),
  };

  factory BatteryHealthState.fromJson(Object? value) {
    final map = _requireMap(value, 'health.battery');
    return BatteryHealthState(
      stateOfHealthPercent: _requireRange(
        map['stateOfHealthPercent'],
        'health.battery.stateOfHealthPercent',
        0,
        100,
      ),
      temperatureC: _requireRange(
        map['temperatureC'],
        'health.battery.temperatureC',
        -40,
        90,
      ),
      capacityKwh: _requireRange(
        map['capacityKwh'],
        'health.battery.capacityKwh',
        10,
        200,
      ),
      chargeCycles: _requireIntRange(
        map['chargeCycles'],
        'health.battery.chargeCycles',
        0,
        10000,
      ),
      ageMonths: _requireIntRange(
        map['ageMonths'],
        'health.battery.ageMonths',
        0,
        600,
      ),
      voltageV: _requireRange(
        map['voltageV'],
        'health.battery.voltageV',
        200,
        1000,
      ),
    );
  }

  BatteryHealthState copyWith({
    double? stateOfHealthPercent,
    double? temperatureC,
    double? capacityKwh,
    int? chargeCycles,
    int? ageMonths,
    double? voltageV,
  }) => BatteryHealthState(
    stateOfHealthPercent: stateOfHealthPercent ?? this.stateOfHealthPercent,
    temperatureC: temperatureC ?? this.temperatureC,
    capacityKwh: capacityKwh ?? this.capacityKwh,
    chargeCycles: chargeCycles ?? this.chargeCycles,
    ageMonths: ageMonths ?? this.ageMonths,
    voltageV: voltageV ?? this.voltageV,
  );
}

class MotorHealthState {
  const MotorHealthState({
    this.healthPercent = 96,
    this.temperatureC = 25,
    this.rpm = 0,
    this.efficiencyPercent = 92,
    this.status = MotorOperatingStatus.off,
  });

  final double healthPercent;
  final double temperatureC;
  final int rpm;
  final double efficiencyPercent;
  final MotorOperatingStatus status;

  Map<String, Object> toJson() => {
    'healthPercent': _round(healthPercent),
    'temperatureC': _round(temperatureC),
    'rpm': rpm,
    'efficiencyPercent': _round(efficiencyPercent),
    'status': status.name,
  };

  factory MotorHealthState.fromJson(Object? value) {
    final map = _requireMap(value, 'health.motor');
    final status = MotorOperatingStatus.values
        .where((candidate) => candidate.name == map['status'])
        .firstOrNull;
    if (status == null) {
      throw const FormatException('health.motor.status is not supported.');
    }
    return MotorHealthState(
      healthPercent: _requireRange(
        map['healthPercent'],
        'health.motor.healthPercent',
        0,
        100,
      ),
      temperatureC: _requireRange(
        map['temperatureC'],
        'health.motor.temperatureC',
        -40,
        200,
      ),
      rpm: _requireIntRange(map['rpm'], 'health.motor.rpm', 0, 20000),
      efficiencyPercent: _requireRange(
        map['efficiencyPercent'],
        'health.motor.efficiencyPercent',
        0,
        100,
      ),
      status: status,
    );
  }

  MotorHealthState copyWith({
    double? healthPercent,
    double? temperatureC,
    int? rpm,
    double? efficiencyPercent,
    MotorOperatingStatus? status,
  }) => MotorHealthState(
    healthPercent: healthPercent ?? this.healthPercent,
    temperatureC: temperatureC ?? this.temperatureC,
    rpm: rpm ?? this.rpm,
    efficiencyPercent: efficiencyPercent ?? this.efficiencyPercent,
    status: status ?? this.status,
  );
}

class TireState {
  const TireState({this.pressurePsi = 35, this.treadPercent = 85});

  final double pressurePsi;
  final double treadPercent;

  Map<String, Object> toJson() => {
    'pressurePsi': _round(pressurePsi),
    'treadPercent': _round(treadPercent),
  };

  factory TireState.fromJson(Object? value, String field) {
    final map = _requireMap(value, field);
    return TireState(
      pressurePsi: _requireRange(
        map['pressurePsi'],
        '$field.pressurePsi',
        0,
        60,
      ),
      treadPercent: _requireRange(
        map['treadPercent'],
        '$field.treadPercent',
        0,
        100,
      ),
    );
  }

  TireState copyWith({double? pressurePsi, double? treadPercent}) =>
      TireState(
        pressurePsi: pressurePsi ?? this.pressurePsi,
        treadPercent: treadPercent ?? this.treadPercent,
      );
}

class BrakeHealthState {
  const BrakeHealthState({
    this.frontPadPercent = 78,
    this.rearPadPercent = 84,
    this.fluidStatus = BrakeFluidStatus.ok,
  });

  final double frontPadPercent;
  final double rearPadPercent;
  final BrakeFluidStatus fluidStatus;

  Map<String, Object> toJson() => {
    'frontPadPercent': _round(frontPadPercent),
    'rearPadPercent': _round(rearPadPercent),
    'fluidStatus': fluidStatus.name,
  };

  factory BrakeHealthState.fromJson(Object? value) {
    final map = _requireMap(value, 'health.brakes');
    final fluid = BrakeFluidStatus.values
        .where((candidate) => candidate.name == map['fluidStatus'])
        .firstOrNull;
    if (fluid == null) {
      throw const FormatException('health.brakes.fluidStatus is not supported.');
    }
    return BrakeHealthState(
      frontPadPercent: _requireRange(
        map['frontPadPercent'],
        'health.brakes.frontPadPercent',
        0,
        100,
      ),
      rearPadPercent: _requireRange(
        map['rearPadPercent'],
        'health.brakes.rearPadPercent',
        0,
        100,
      ),
      fluidStatus: fluid,
    );
  }

  BrakeHealthState copyWith({
    double? frontPadPercent,
    double? rearPadPercent,
    BrakeFluidStatus? fluidStatus,
  }) => BrakeHealthState(
    frontPadPercent: frontPadPercent ?? this.frontPadPercent,
    rearPadPercent: rearPadPercent ?? this.rearPadPercent,
    fluidStatus: fluidStatus ?? this.fluidStatus,
  );
}

class SoftwareState {
  const SoftwareState({this.version = '4.2.1', this.updateAvailable = false});

  final String version;
  final bool updateAvailable;

  Map<String, Object> toJson() => {
    'version': version,
    'updateAvailable': updateAvailable,
  };

  factory SoftwareState.fromJson(Object? value) {
    final map = _requireMap(value, 'health.software');
    final version = map['version'];
    if (version is! String ||
        version.isEmpty ||
        version.length > 32 ||
        !RegExp(r'^[0-9A-Za-z.+-]+$').hasMatch(version)) {
      throw const FormatException('health.software.version is invalid.');
    }
    return SoftwareState(
      version: version,
      updateAvailable: _requireBool(
        map['updateAvailable'],
        'health.software.updateAvailable',
      ),
    );
  }

  SoftwareState copyWith({String? version, bool? updateAvailable}) =>
      SoftwareState(
        version: version ?? this.version,
        updateAvailable: updateAvailable ?? this.updateAvailable,
      );
}

/// Optional component-health section of a state snapshot. Snapshots from
/// simulators that predate it simply omit `state.health`.
class VehicleHealthState {
  const VehicleHealthState({
    this.battery = const BatteryHealthState(),
    this.motor = const MotorHealthState(),
    this.tires = const {
      VehicleDoor.frontLeft: TireState(),
      VehicleDoor.frontRight: TireState(),
      VehicleDoor.rearLeft: TireState(),
      VehicleDoor.rearRight: TireState(),
    },
    this.brakes = const BrakeHealthState(),
    this.software = const SoftwareState(),
    this.odometerKm = 18450,
  });

  final BatteryHealthState battery;
  final MotorHealthState motor;

  /// Keyed by wheel position; uses the same four positions as the doors.
  final Map<VehicleDoor, TireState> tires;
  final BrakeHealthState brakes;
  final SoftwareState software;
  final double odometerKm;

  TireState tire(VehicleDoor position) => tires[position] ?? const TireState();

  Map<String, Object> toJson() => {
    'battery': battery.toJson(),
    'motor': motor.toJson(),
    'tires': {
      for (final position in VehicleDoor.values)
        position.wireName: tire(position).toJson(),
    },
    'brakes': brakes.toJson(),
    'software': software.toJson(),
    'odometerKm': _round(odometerKm, 2),
  };

  factory VehicleHealthState.fromJson(Object? value) {
    final map = _requireMap(value, 'health');
    final tiresMap = _requireMap(map['tires'], 'health.tires');
    if (tiresMap.length != VehicleDoor.values.length) {
      throw const FormatException('health.tires must contain exactly four tires.');
    }
    return VehicleHealthState(
      battery: BatteryHealthState.fromJson(map['battery']),
      motor: MotorHealthState.fromJson(map['motor']),
      tires: Map.unmodifiable({
        for (final position in VehicleDoor.values)
          position: TireState.fromJson(
            tiresMap[position.wireName],
            'health.tires.${position.wireName}',
          ),
      }),
      brakes: BrakeHealthState.fromJson(map['brakes']),
      software: SoftwareState.fromJson(map['software']),
      odometerKm: _requireRange(
        map['odometerKm'],
        'health.odometerKm',
        0,
        2000000,
      ),
    );
  }

  VehicleHealthState copyWith({
    BatteryHealthState? battery,
    MotorHealthState? motor,
    Map<VehicleDoor, TireState>? tires,
    BrakeHealthState? brakes,
    SoftwareState? software,
    double? odometerKm,
  }) => VehicleHealthState(
    battery: battery ?? this.battery,
    motor: motor ?? this.motor,
    tires: tires ?? this.tires,
    brakes: brakes ?? this.brakes,
    software: software ?? this.software,
    odometerKm: odometerKm ?? this.odometerKm,
  );
}

class VehicleControlState {
  const VehicleControlState({
    this.speedKph = 0,
    this.batteryPercent = 75,
    this.rangeKm = 280,
    this.vehicleOn = false,
    this.lightsOn = false,
    this.chargingConnected = false,
    this.chargingPowerKw = 0,
    this.chargingInterrupted = false,
    this.targetChargePercent = 80,
    this.climateOn = false,
    this.seatHeatingEnabled = false,
    this.cabinTemperatureC = 21,
    this.targetTemperatureC = 21,
    this.fanLevel = 1,
    this.doors = const {
      VehicleDoor.frontLeft: VehicleDoorState(),
      VehicleDoor.frontRight: VehicleDoorState(),
      VehicleDoor.rearLeft: VehicleDoorState(),
      VehicleDoor.rearRight: VehicleDoorState(),
    },
    this.windows = const {
      VehicleDoor.frontLeft: 0,
      VehicleDoor.frontRight: 0,
      VehicleDoor.rearLeft: 0,
      VehicleDoor.rearRight: 0,
    },
    this.health,
  });

  final double speedKph;
  final double batteryPercent;
  final double rangeKm;
  final bool vehicleOn;
  final bool lightsOn;
  final bool chargingConnected;
  final double chargingPowerKw;
  final bool chargingInterrupted;
  final int targetChargePercent;
  final bool climateOn;
  final bool seatHeatingEnabled;
  final double cabinTemperatureC;
  final double targetTemperatureC;
  final int fanLevel;
  final Map<VehicleDoor, VehicleDoorState> doors;
  final Map<VehicleDoor, int> windows;

  /// Null when the sender does not report component health.
  final VehicleHealthState? health;

  Map<String, Object> toJson() => {
    'speedKph': speedKph,
    'batteryPercent': batteryPercent,
    'rangeKm': rangeKm,
    'vehicleOn': vehicleOn,
    'lightsOn': lightsOn,
    'chargingConnected': chargingConnected,
    'chargingPowerKw': chargingPowerKw,
    'chargingInterrupted': chargingInterrupted,
    'targetChargePercent': targetChargePercent,
    'climateOn': climateOn,
    'seatHeatingEnabled': seatHeatingEnabled,
    'cabinTemperatureC': cabinTemperatureC,
    'targetTemperatureC': targetTemperatureC,
    'fanLevel': fanLevel,
    'doors': {
      for (final door in VehicleDoor.values)
        door.wireName: (doors[door] ?? const VehicleDoorState()).toJson(),
    },
    'windows': {
      for (final door in VehicleDoor.values)
        door.wireName: windows[door] ?? 0,
    },
    if (health != null) 'health': health!.toJson(),
  };

  factory VehicleControlState.fromJson(Object? value) {
    final map = _requireMap(value, 'state');
    final doorsMap = _requireMap(map['doors'], 'state.doors');
    final windowsMap = _requireMap(map['windows'], 'state.windows');
    if (doorsMap.length != VehicleDoor.values.length ||
        windowsMap.length != VehicleDoor.values.length) {
      throw const FormatException('State must contain exactly four doors and windows.');
    }

    final doors = <VehicleDoor, VehicleDoorState>{};
    final windows = <VehicleDoor, int>{};
    for (final door in VehicleDoor.values) {
      doors[door] = VehicleDoorState.fromJson(doorsMap[door.wireName]);
      final level = _requireInt(
        windowsMap[door.wireName],
        'state.windows.${door.wireName}',
      );
      if (level < 0 || level > 100) {
        throw FormatException(
          'state.windows.${door.wireName} must be between 0 and 100.',
        );
      }
      windows[door] = level;
    }

    final speed = _requireNumber(map['speedKph'], 'state.speedKph');
    final battery = _requireNumber(
      map['batteryPercent'],
      'state.batteryPercent',
    );
    final range = _requireNumber(map['rangeKm'], 'state.rangeKm');
    final chargingPower = _requireNumber(
      map['chargingPowerKw'],
      'state.chargingPowerKw',
    );
    final targetCharge = _requireInt(
      map['targetChargePercent'],
      'state.targetChargePercent',
    );
    final cabinTemp = _requireNumber(
      map['cabinTemperatureC'],
      'state.cabinTemperatureC',
    );
    final targetTemp = _requireNumber(
      map['targetTemperatureC'],
      'state.targetTemperatureC',
    );
    final fanLevel = _requireInt(map['fanLevel'], 'state.fanLevel');
    final vehicleOn = _requireBool(map['vehicleOn'], 'state.vehicleOn');
    final chargingConnected = _requireBool(
      map['chargingConnected'],
      'state.chargingConnected',
    );
    final chargingInterrupted = _requireBool(
      map['chargingInterrupted'],
      'state.chargingInterrupted',
    );

    if (speed < 0 || battery < 0 || battery > 100 || range < 0 ||
        chargingPower < 0 || targetCharge < 50 || targetCharge > 100 ||
        cabinTemp < -40 || cabinTemp > 85 || targetTemp < 16 ||
        targetTemp > 30 || fanLevel < 0 || fanLevel > 5 ||
        (chargingConnected && (vehicleOn || speed > 0)) ||
        (!chargingConnected && chargingPower > 0) ||
        (chargingConnected && chargingInterrupted)) {
      throw const FormatException(
        'Vehicle state contains an invalid or out-of-range value.',
      );
    }

    return VehicleControlState(
      speedKph: speed,
      batteryPercent: battery,
      rangeKm: range,
      vehicleOn: vehicleOn,
      lightsOn: _requireBool(map['lightsOn'], 'state.lightsOn'),
      chargingConnected: chargingConnected,
      chargingPowerKw: chargingPower,
      chargingInterrupted: chargingInterrupted,
      targetChargePercent: targetCharge,
      climateOn: _requireBool(map['climateOn'], 'state.climateOn'),
      seatHeatingEnabled: _requireBool(
        map['seatHeatingEnabled'],
        'state.seatHeatingEnabled',
      ),
      cabinTemperatureC: cabinTemp,
      targetTemperatureC: targetTemp,
      fanLevel: fanLevel,
      doors: Map.unmodifiable(doors),
      windows: Map.unmodifiable(windows),
      health: map['health'] == null
          ? null
          : VehicleHealthState.fromJson(map['health']),
    );
  }

  VehicleControlState copyWith({
    double? speedKph,
    double? batteryPercent,
    double? rangeKm,
    bool? vehicleOn,
    bool? lightsOn,
    bool? chargingConnected,
    double? chargingPowerKw,
    bool? chargingInterrupted,
    int? targetChargePercent,
    bool? climateOn,
    bool? seatHeatingEnabled,
    double? cabinTemperatureC,
    double? targetTemperatureC,
    int? fanLevel,
    Map<VehicleDoor, VehicleDoorState>? doors,
    Map<VehicleDoor, int>? windows,
    VehicleHealthState? health,
  }) => VehicleControlState(
    speedKph: speedKph ?? this.speedKph,
    batteryPercent: batteryPercent ?? this.batteryPercent,
    rangeKm: rangeKm ?? this.rangeKm,
    vehicleOn: vehicleOn ?? this.vehicleOn,
    lightsOn: lightsOn ?? this.lightsOn,
    chargingConnected: chargingConnected ?? this.chargingConnected,
    chargingPowerKw: chargingPowerKw ?? this.chargingPowerKw,
    chargingInterrupted: chargingInterrupted ?? this.chargingInterrupted,
    targetChargePercent: targetChargePercent ?? this.targetChargePercent,
    climateOn: climateOn ?? this.climateOn,
    seatHeatingEnabled: seatHeatingEnabled ?? this.seatHeatingEnabled,
    cabinTemperatureC: cabinTemperatureC ?? this.cabinTemperatureC,
    targetTemperatureC: targetTemperatureC ?? this.targetTemperatureC,
    fanLevel: fanLevel ?? this.fanLevel,
    doors: doors ?? this.doors,
    windows: windows ?? this.windows,
    health: health ?? this.health,
  );
}

class VehicleStateSnapshot {
  const VehicleStateSnapshot({
    required this.vehicleId,
    required this.sequence,
    required this.timestampMillis,
    required this.state,
  });

  final String vehicleId;
  final int sequence;
  final int timestampMillis;
  final VehicleControlState state;

  Map<String, Object> toJson() => {
    'v': 1,
    'type': 'state',
    'vehicleId': vehicleId,
    'sequence': sequence,
    'timestampMillis': timestampMillis,
    'state': state.toJson(),
  };

  String encode() => jsonEncode(toJson());

  factory VehicleStateSnapshot.decode(String value) {
    final map = _requireMap(jsonDecode(value), 'snapshot');
    if (map['v'] != 1 || map['type'] != 'state') {
      throw const FormatException('Unsupported vehicle state packet.');
    }
    final vehicleId = map['vehicleId'];
    if (vehicleId is! String || vehicleId.trim().isEmpty || vehicleId.length > 128) {
      throw const FormatException('Invalid vehicle ID in state packet.');
    }
    final sequence = _requireInt(map['sequence'], 'snapshot.sequence');
    final timestamp = _requireInt(
      map['timestampMillis'],
      'snapshot.timestampMillis',
    );
    if (sequence < 0 || timestamp < 0) {
      throw const FormatException('Invalid snapshot sequence or timestamp.');
    }
    return VehicleStateSnapshot(
      vehicleId: vehicleId,
      sequence: sequence,
      timestampMillis: timestamp,
      state: VehicleControlState.fromJson(map['state']),
    );
  }
}

class VehicleControlCommand {
  const VehicleControlCommand({
    required this.requestId,
    required this.action,
    this.door,
    this.enabled,
    this.level,
    this.temperatureC,
  });

  final String requestId;
  final String action;
  final VehicleDoor? door;
  final bool? enabled;
  final int? level;
  final double? temperatureC;

  Map<String, Object> toJson() {
    final result = <String, Object>{
      'v': 1,
      'type': 'command',
      'requestId': requestId,
      'action': action,
    };
    final doorValue = door;
    final enabledValue = enabled;
    final levelValue = level;
    final temperatureValue = temperatureC;
    if (doorValue != null) result['door'] = doorValue.wireName;
    if (enabledValue != null) result['enabled'] = enabledValue;
    if (levelValue != null) result['level'] = levelValue;
    if (temperatureValue != null) {
      result['temperatureC'] = temperatureValue;
    }
    return result;
  }

  String encode() => jsonEncode(toJson());

  factory VehicleControlCommand.decode(String value) {
    final map = _requireMap(jsonDecode(value), 'command');
    if (map['v'] != 1 || map['type'] != 'command') {
      throw const FormatException('Unsupported vehicle command.');
    }
    final requestId = map['requestId'];
    final action = map['action'];
    if (requestId is! String ||
        requestId.isEmpty ||
        requestId.length > 64 ||
        action is! String) {
      throw const FormatException('Invalid vehicle command header.');
    }
    const allowedActions = {
      'doorOpen',
      'doorLock',
      'windowLevel',
      'climate',
      'targetTemperature',
      'fanLevel',
      'chargingConnected',
      'targetCharge',
      'headlights',
      'vehicleOn',
      'seatHeating',
      'speed',
    };
    if (!allowedActions.contains(action)) {
      throw FormatException('Unsupported command action: $action.');
    }

    VehicleDoor? door;
    if (map.containsKey('door')) {
      door = VehicleDoor.values
          .where((candidate) => candidate.wireName == map['door'])
          .firstOrNull;
      if (door == null) throw const FormatException('Invalid command door.');
    }
    final enabled = map['enabled'];
    if (enabled != null && enabled is! bool) {
      throw const FormatException('Command enabled must be a boolean.');
    }
    final levelValue = map['level'];
    final level = levelValue == null
        ? null
        : _requireInt(levelValue, 'command.level');
    final temperatureValue = map['temperatureC'];
    final temperature = temperatureValue == null
        ? null
        : _requireNumber(temperatureValue, 'command.temperatureC');

    final requiresDoor = action == 'doorOpen' ||
        action == 'doorLock' ||
        action == 'windowLevel';
    if (requiresDoor != (door != null)) {
      throw const FormatException('Command door does not match its action.');
    }
    if ((action == 'doorOpen' ||
            action == 'doorLock' ||
            action == 'climate' ||
            action == 'chargingConnected' ||
            action == 'headlights' ||
            action == 'seatHeating' ||
            action == 'vehicleOn') &&
        enabled == null) {
      throw const FormatException('Command requires an enabled value.');
    }
    if ((action == 'windowLevel' ||
            action == 'targetCharge' ||
            action == 'fanLevel' ||
            action == 'speed') &&
        level == null) {
      throw const FormatException('Command requires a level value.');
    }
    if (action == 'targetTemperature' && temperature == null) {
      throw const FormatException('Command requires a temperature value.');
    }
    return VehicleControlCommand(
      requestId: requestId,
      action: action,
      door: door,
      enabled: enabled as bool?,
      level: level,
      temperatureC: temperature,
    );
  }
}

VehicleControlState applyVehicleCommand(
  VehicleControlState state,
  VehicleControlCommand command,
) {
  switch (command.action) {
    case 'doorOpen':
      if (command.enabled == true && state.speedKph > 0) {
        throw const VehicleSafetyException(
          'Doors cannot be opened while the vehicle is moving.',
        );
      }
      final doors = Map<VehicleDoor, VehicleDoorState>.of(state.doors);
      final current = doors[command.door] ?? const VehicleDoorState();
      doors[command.door!] = VehicleDoorState(
        open: command.enabled!,
        locked: command.enabled! ? false : current.locked,
      );
      return state.copyWith(doors: doors);
    case 'doorLock':
      final doors = Map<VehicleDoor, VehicleDoorState>.of(state.doors);
      final current = doors[command.door] ?? const VehicleDoorState();
      if (command.enabled == true && current.open) {
        throw const VehicleSafetyException('An open door cannot be locked.');
      }
      doors[command.door!] = VehicleDoorState(
        open: current.open,
        locked: command.enabled!,
      );
      return state.copyWith(doors: doors);
    case 'windowLevel':
      if (command.level! < 0 || command.level! > 100) {
        throw const VehicleSafetyException(
          'Window level must be between 0 and 100.',
        );
      }
      return state.copyWith(
        windows: {...state.windows, command.door!: command.level!},
      );
    case 'climate':
      return state.copyWith(climateOn: command.enabled);
    case 'seatHeating':
      return state.copyWith(seatHeatingEnabled: command.enabled);
    case 'targetTemperature':
      if (command.temperatureC! < 16 || command.temperatureC! > 30) {
        throw const VehicleSafetyException(
          'Climate target must be between 16 and 30 degrees.',
        );
      }
      return state.copyWith(targetTemperatureC: command.temperatureC);
    case 'fanLevel':
      if (command.level! < 0 || command.level! > 5) {
        throw const VehicleSafetyException('Fan level must be between 0 and 5.');
      }
      return state.copyWith(fanLevel: command.level);
    case 'chargingConnected':
      if (command.enabled == true &&
          (state.vehicleOn || state.speedKph > 0)) {
        throw const VehicleSafetyException(
          'Stop and turn the vehicle off before connecting the charger.',
        );
      }
      return state.copyWith(
        chargingConnected: command.enabled,
        chargingPowerKw: command.enabled! ? 7.2 : 0,
        chargingInterrupted: false,
      );
    case 'targetCharge':
      if (command.level! < 50 || command.level! > 100) {
        throw const VehicleSafetyException(
          'Charge target must be between 50 and 100 percent.',
        );
      }
      return state.copyWith(targetChargePercent: command.level);
    case 'headlights':
      return state.copyWith(lightsOn: command.enabled);
    case 'vehicleOn':
      if (command.enabled == true && state.chargingConnected) {
        throw const VehicleSafetyException(
          'Disconnect the charger before turning the vehicle on.',
        );
      }
      return state.copyWith(vehicleOn: command.enabled);
    case 'speed':
      if (command.level! < 0 || command.level! > 240) {
        throw const VehicleSafetyException(
          'Vehicle speed must be between 0 and 240 km/h.',
        );
      }
      return state.copyWith(speedKph: command.level!.toDouble());
    default:
      throw ArgumentError.value(command.action, 'action', 'Unsupported command.');
  }
}

class VehicleSafetyException implements Exception {
  const VehicleSafetyException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BleFrameCodec {
  const BleFrameCodec._();

  static List<Uint8List> fragment(
    List<int> message, {
    int maximumFrameLength = bleDefaultFrameLength,
    required int messageId,
  }) {
    if (maximumFrameLength <= bleFrameHeaderLength || messageId < 0 || messageId > 255) {
      throw ArgumentError('Invalid BLE frame length or message ID.');
    }
    if (message.isEmpty || message.length > bleMaximumMessageLength) {
      throw ArgumentError.value(message.length, 'message.length');
    }
    final chunkLength = maximumFrameLength - bleFrameHeaderLength;
    final count = (message.length / chunkLength).ceil();
    if (count > 255) throw ArgumentError('BLE message requires too many frames.');
    final frames = <Uint8List>[];
    for (var index = 0; index < count; index++) {
      final start = index * chunkLength;
      final end = (start + chunkLength).clamp(0, message.length);
      frames.add(
        Uint8List.fromList([
          0xE7,
          messageId,
          count,
          index,
          ...message.sublist(start, end),
        ]),
      );
    }
    return frames;
  }
}

class BleFrameAssembler {
  int? _messageId;
  int? _frameCount;
  final Map<int, Uint8List> _frames = {};
  int _byteLength = 0;

  Uint8List? add(List<int> frame) {
    if (frame.length <= bleFrameHeaderLength ||
        frame.length > 512 ||
        frame[0] != 0xE7) {
      throw const FormatException('Invalid BLE frame.');
    }
    final messageId = frame[1];
    final frameCount = frame[2];
    final index = frame[3];
    if (frameCount == 0 || index >= frameCount) {
      throw const FormatException('Invalid BLE frame sequence.');
    }
    if (_messageId != messageId || _frameCount != frameCount) {
      reset();
      _messageId = messageId;
      _frameCount = frameCount;
    }
    if (_frames.containsKey(index)) return null;
    final payload = Uint8List.fromList(frame.sublist(bleFrameHeaderLength));
    _byteLength += payload.length;
    if (_byteLength > bleMaximumMessageLength) {
      reset();
      throw const FormatException('BLE message exceeds the maximum length.');
    }
    _frames[index] = payload;
    if (_frames.length != frameCount) return null;
    final bytes = BytesBuilder(copy: false);
    for (var part = 0; part < frameCount; part++) {
      final payloadPart = _frames[part];
      if (payloadPart == null) return null;
      bytes.add(payloadPart);
    }
    final message = bytes.takeBytes();
    reset();
    return message;
  }

  void reset() {
    _messageId = null;
    _frameCount = null;
    _frames.clear();
    _byteLength = 0;
  }
}

Map<String, Object?> _requireMap(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object.');
  return value.map((key, value) {
    if (key is! String) throw FormatException('$field keys must be strings.');
    return MapEntry(key, value);
  });
}

bool _requireBool(Object? value, String field) {
  if (value is! bool) throw FormatException('$field must be a boolean.');
  return value;
}

int _requireInt(Object? value, String field) {
  if (value is! int) throw FormatException('$field must be an integer.');
  return value;
}

double _requireNumber(Object? value, String field) {
  if (value is! num || !value.isFinite) {
    throw FormatException('$field must be a finite number.');
  }
  return value.toDouble();
}

double _requireRange(Object? value, String field, double min, double max) {
  final number = _requireNumber(value, field);
  if (number < min || number > max) {
    throw FormatException('$field must be between $min and $max.');
  }
  return number;
}

int _requireIntRange(Object? value, String field, int min, int max) {
  final number = _requireInt(value, field);
  if (number < min || number > max) {
    throw FormatException('$field must be between $min and $max.');
  }
  return number;
}

/// Keeps the BLE payload short; senders may hold more precise values.
num _round(double value, [int decimals = 1]) {
  final factor = decimals == 2 ? 100 : 10;
  final rounded = (value * factor).round() / factor;
  return rounded == rounded.roundToDouble() ? rounded.round() : rounded;
}
