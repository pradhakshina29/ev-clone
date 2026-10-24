import { model, Schema, type InferSchemaType } from 'mongoose';

// Same keys and limits as the original preference rules and
// PassengerProfile / VehicleAlert in lib/models/vehicle_controls.dart.
export const MAX_PASSENGER_PROFILES = 20;
export const MAX_ALERT_HISTORY = 50;
export const MAX_ACTIVE_ALERT_KEYS = 32;

const passengerProfileSchema = new Schema(
  {
    id: { type: String, required: true, maxlength: 64 },
    name: { type: String, required: true, trim: true, minlength: 1, maxlength: 80 },
    role: { type: String, enum: ['driver', 'passenger', 'child', 'caregiver'], required: true },
    seatPosition: {
      type: String,
      enum: ['frontLeft', 'frontRight', 'rearLeft', 'rearRight'],
      required: true,
    },
    preferredTemperatureC: { type: Number, required: true, min: 16, max: 30 },
    fanLevel: { type: Number, required: true, min: 0, max: 5 },
    seatHeating: { type: Boolean, required: true },
    leftMirrorHorizontal: { type: Number, min: -20, max: 20, default: 0 },
    leftMirrorVertical: { type: Number, min: -20, max: 20, default: 0 },
    rightMirrorHorizontal: { type: Number, min: -20, max: 20, default: 0 },
    rightMirrorVertical: { type: Number, min: -20, max: 20, default: 0 },
    lastUsedAt: { type: String, maxlength: 40, default: '' },
  },
  { _id: false },
);

const alertSchema = new Schema(
  {
    id: { type: String, required: true, maxlength: 128 },
    kind: { type: String, required: true, maxlength: 64 },
    title: { type: String, required: true, maxlength: 200 },
    message: { type: String, required: true, maxlength: 1000 },
    severity: { type: String, required: true, maxlength: 20 },
    timestamp: { type: String, required: true, maxlength: 40 },
    value: { type: String, maxlength: 64 },
    vehicleId: { type: String, maxlength: 64 },
    shownAt: { type: String, maxlength: 40 },
    acknowledgedAt: { type: String, maxlength: 40 },
  },
  { _id: false },
);

function maxItems(limit: number) {
  return {
    validator: (value: unknown[]) => value.length <= limit,
    message: `{PATH} can have at most ${limit} items`,
  };
}

const preferencesSchema = new Schema(
  {
    notificationsEnabled: { type: Boolean, default: true },
    safetyAlertsEnabled: { type: Boolean, default: true },
    batteryAlertsEnabled: { type: Boolean, default: true },
    chargingAlertsEnabled: { type: Boolean, default: true },
    passengerProfiles: {
      type: [passengerProfileSchema],
      default: [],
      validate: maxItems(MAX_PASSENGER_PROFILES),
    },
    selectedProfileId: { type: String, maxlength: 64, default: null },
    alertHistory: { type: [alertSchema], default: [], validate: maxItems(MAX_ALERT_HISTORY) },
    activeAlertKeys: {
      type: [{ type: String, maxlength: 64 }],
      default: [],
      validate: maxItems(MAX_ACTIVE_ALERT_KEYS),
    },
  },
  { _id: false },
);

const controlsPreferencesSchema = new Schema(
  {
    _id: { type: String, required: true }, // `${uid}:${vehicleId}`
    uid: { type: String, required: true },
    vehicleId: { type: String, required: true, maxlength: 64 },
    preferences: { type: preferencesSchema, required: true },
  },
  { timestamps: true, versionKey: false },
);

export function controlsPreferencesId(uid: string, vehicleId: string): string {
  return `${uid}:${vehicleId}`;
}

export type ControlsPreferencesDocument = InferSchemaType<typeof controlsPreferencesSchema>;
export const ControlsPreferences = model(
  'ControlsPreferences',
  controlsPreferencesSchema,
  'controlsPreferences',
);
