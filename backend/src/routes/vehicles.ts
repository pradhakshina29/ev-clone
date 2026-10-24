import { Router } from 'express';
import { z } from 'zod';

import { currentUser } from '../middleware/auth.js';
import { validate, validBody, validParams } from '../middleware/validate.js';
import { rupeesToPaise } from '../models/common.js';
import {
  ControlsPreferences,
  controlsPreferencesId,
  MAX_ACTIVE_ALERT_KEYS,
  MAX_ALERT_HISTORY,
  MAX_PASSENGER_PROFILES,
} from '../models/controlsPreferences.js';
import { MaintenanceRecord } from '../models/maintenanceRecord.js';
import {
  maintenanceJson,
  vehicleJson,
  type MaintenanceRecordRecord,
} from '../services/serialize.js';
import {
  requireOwnedVehicle,
  updateVehicleConfiguration,
  verifyConnectedVehicleDetails,
} from '../services/vehicles.js';
import { isoDate, requiredText, rupees, text, vehicleDetails, vehicleIdParams } from './schemas.js';

const configurationSchema = z.object({
  maximumRangeKm: z.number().finite().positive().max(5000),
  batteryCapacityKwh: z.number().finite().positive().max(1000).nullable().optional(),
  connectorType: text(40),
});

const maintenanceSchema = z.object({
  serviceType: requiredText(80),
  category: text(40),
  serviceDate: isoDate,
  nextServiceDate: isoDate.nullable().optional(),
  odometerKm: z.number().finite().min(0).max(10_000_000).nullable().optional(),
  cost: rupees.nullable().optional(),
  serviceCenter: text(120).optional(),
  notes: text(1000).optional(),
});

// Mirrors PassengerProfile / VehicleAlert / VehicleControlsPreferences in
// lib/models/vehicle_controls.dart and the original preference limits.
const mirror = z.number().finite().min(-20).max(20);
const passengerProfileSchema = z.strictObject({
  id: requiredText(64),
  name: requiredText(80),
  role: z.enum(['driver', 'passenger', 'child', 'caregiver']),
  seatPosition: z.enum(['frontLeft', 'frontRight', 'rearLeft', 'rearRight']),
  preferredTemperatureC: z.number().int().min(16).max(30),
  fanLevel: z.number().int().min(0).max(5),
  seatHeating: z.boolean(),
  leftMirrorHorizontal: mirror.default(0),
  leftMirrorVertical: mirror.default(0),
  rightMirrorHorizontal: mirror.default(0),
  rightMirrorVertical: mirror.default(0),
  lastUsedAt: text(40).default(''),
});
const alertSchema = z.strictObject({
  id: requiredText(128),
  kind: requiredText(64),
  title: requiredText(200),
  message: requiredText(1000),
  severity: requiredText(20),
  timestamp: requiredText(40),
  // Added with must-acknowledge alerts; older records have none of these.
  value: text(64).optional(),
  vehicleId: text(64).optional(),
  shownAt: text(40).optional(),
  acknowledgedAt: text(40).optional(),
});
const preferencesSchema = z.strictObject({
  notificationsEnabled: z.boolean(),
  safetyAlertsEnabled: z.boolean(),
  batteryAlertsEnabled: z.boolean(),
  chargingAlertsEnabled: z.boolean(),
  passengerProfiles: z.array(passengerProfileSchema).max(MAX_PASSENGER_PROFILES),
  selectedProfileId: z.string().max(64).nullable(),
  alertHistory: z.array(alertSchema).max(MAX_ALERT_HISTORY),
  activeAlertKeys: z.array(z.string().max(64)).max(MAX_ACTIVE_ALERT_KEYS),
});
const savePreferencesSchema = z.object({ preferences: preferencesSchema });

const defaultPreferences = {
  notificationsEnabled: true,
  safetyAlertsEnabled: true,
  batteryAlertsEnabled: true,
  chargingAlertsEnabled: true,
  passengerProfiles: [],
  selectedProfileId: null,
  alertHistory: [],
  activeAlertKeys: [],
};

export function vehiclesRouter() {
  const router = Router();

  router.post(
    '/vehicles/verify',
    validate({ body: z.object(vehicleDetails) }),
    async (req, res) => {
      const body = validBody(req, z.object(vehicleDetails));
      const vehicle = await verifyConnectedVehicleDetails(currentUser(req).uid, body);
      res.json({ vehicle: vehicle ? vehicleJson(vehicle) : null });
    },
  );

  // Vehicle metadata only; live measurements come from BLE.
  router.get('/vehicles/:vehicleId', validate({ params: vehicleIdParams }), async (req, res) => {
    const { vehicleId } = validParams(req, vehicleIdParams);
    const vehicle = await requireOwnedVehicle(currentUser(req).uid, vehicleId, {
      requireActive: false,
    });
    res.json(vehicleJson(vehicle));
  });

  router.patch(
    '/vehicles/:vehicleId/configuration',
    validate({ params: vehicleIdParams, body: configurationSchema }),
    async (req, res) => {
      const { vehicleId } = validParams(req, vehicleIdParams);
      const body = validBody(req, configurationSchema);
      const vehicle = await updateVehicleConfiguration(currentUser(req).uid, vehicleId, body);
      res.json(vehicleJson(vehicle));
    },
  );

  router.get(
    '/vehicles/:vehicleId/maintenance',
    validate({ params: vehicleIdParams }),
    async (req, res) => {
      const { vehicleId } = validParams(req, vehicleIdParams);
      await requireOwnedVehicle(currentUser(req).uid, vehicleId, { requireActive: false });
      const records = await MaintenanceRecord.find({ vehicleId })
        .sort({ serviceDate: -1, _id: -1 })
        .limit(500)
        .lean<MaintenanceRecordRecord[]>();
      res.json({ records: records.map(maintenanceJson) });
    },
  );

  router.post(
    '/vehicles/:vehicleId/maintenance',
    validate({ params: vehicleIdParams, body: maintenanceSchema }),
    async (req, res) => {
      const { vehicleId } = validParams(req, vehicleIdParams);
      const { uid } = currentUser(req);
      const body = validBody(req, maintenanceSchema);
      await requireOwnedVehicle(uid, vehicleId);
      const record = await MaintenanceRecord.create({
        vehicleId,
        createdByUid: uid,
        serviceType: body.serviceType,
        category: body.category,
        serviceDate: body.serviceDate,
        nextServiceDate: body.nextServiceDate ?? null,
        odometerKm: body.odometerKm ?? null,
        costPaise: body.cost === null || body.cost === undefined ? null : rupeesToPaise(body.cost),
        serviceCenter: body.serviceCenter ?? '',
        notes: body.notes ?? '',
        status: 'Completed',
        source: 'user_entered',
      });
      res.status(201).json(maintenanceJson(record.toObject() as MaintenanceRecordRecord));
    },
  );

  router.get(
    '/vehicles/:vehicleId/controls-preferences',
    validate({ params: vehicleIdParams }),
    async (req, res) => {
      const { vehicleId } = validParams(req, vehicleIdParams);
      const { uid } = currentUser(req);
      await requireOwnedVehicle(uid, vehicleId);
      const saved = await ControlsPreferences.findById(
        controlsPreferencesId(uid, vehicleId),
      ).lean();
      res.json({ vehicleId, preferences: saved?.preferences ?? defaultPreferences });
    },
  );

  router.put(
    '/vehicles/:vehicleId/controls-preferences',
    validate({ params: vehicleIdParams, body: savePreferencesSchema }),
    async (req, res) => {
      const { vehicleId } = validParams(req, vehicleIdParams);
      const { uid } = currentUser(req);
      const { preferences } = validBody(req, savePreferencesSchema);
      await requireOwnedVehicle(uid, vehicleId);
      const saved = await ControlsPreferences.findByIdAndUpdate(
        controlsPreferencesId(uid, vehicleId),
        { uid, vehicleId, preferences },
        { upsert: true, new: true, runValidators: true },
      ).lean();
      res.json({ vehicleId, preferences: saved?.preferences ?? preferences });
    },
  );

  return router;
}
