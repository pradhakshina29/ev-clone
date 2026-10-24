import request from 'supertest';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { CardTransaction } from '../src/models/cardTransaction.js';
import { ChargingCard } from '../src/models/chargingCard.js';
import { ChargingSession } from '../src/models/chargingSession.js';
import * as models from '../src/models/index.js';
import { Vehicle } from '../src/models/vehicle.js';
import { apiApp, EV001, EV002, seedCard, seedOwners } from './fixtures.js';
import { bearer } from './helpers.js';

beforeAll(async () => {
  for (const model of Object.values(models)) {
    if (typeof model === 'function' && 'createIndexes' in model) await model.createIndexes();
  }
});

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]);
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16]);

const validPreferences = {
  notificationsEnabled: true,
  safetyAlertsEnabled: false,
  batteryAlertsEnabled: true,
  chargingAlertsEnabled: true,
  passengerProfiles: [
    {
      id: 'p1',
      name: 'Driver',
      role: 'driver',
      seatPosition: 'frontLeft',
      preferredTemperatureC: 22,
      fanLevel: 2,
      seatHeating: true,
      leftMirrorHorizontal: 0,
      leftMirrorVertical: 0,
      rightMirrorHorizontal: 0,
      rightMirrorVertical: 0,
      lastUsedAt: '',
    },
  ],
  selectedProfileId: 'p1',
  alertHistory: [],
  activeAlertKeys: ['lowBattery'],
};

const cardBody = {
  cardType: 'EV Charging Card',
  cardLastFour: '1234',
  maskedCardNumber: 'XXXX XXXX XXXX 1234',
  cardHolderName: 'Alice',
  expiryDate: '2030-01-01T00:00:00.000Z',
};

// Every authenticated route, with a body that would otherwise be valid.
const vehicleRoutes: [method: 'get' | 'post' | 'put' | 'patch', path: string, body?: object][] = [
  ['get', '/v1/vehicles/EV002'],
  ['patch', '/v1/vehicles/EV002/configuration', { maximumRangeKm: 400, connectorType: 'CCS2' }],
  ['get', '/v1/vehicles/EV002/maintenance'],
  [
    'post',
    '/v1/vehicles/EV002/maintenance',
    { serviceType: 'Tyres', category: 'Tyres', serviceDate: '2026-01-01' },
  ],
  ['get', '/v1/vehicles/EV002/controls-preferences'],
  ['put', '/v1/vehicles/EV002/controls-preferences', { preferences: validPreferences }],
  ['get', '/v1/vehicles/EV002/charging-card'],
  ['post', '/v1/vehicles/EV002/charging-card', cardBody],
  [
    'patch',
    '/v1/vehicles/EV002/charging-card',
    { cardType: 'X', cardHolderName: 'Y', expiryDate: '2030-01-01' },
  ],
  ['get', '/v1/vehicles/EV002/charging-card/transactions'],
  ['post', '/v1/vehicles/EV002/charging-card/paypal-orders', { amountInr: 100 }],
  ['post', '/v1/vehicles/EV002/charging-card/paypal-orders/ORDER1/capture'],
  ['put', '/v1/me/connected-vehicle', { vehicleId: 'EV002' }],
];

const allRoutes: [method: 'get' | 'post' | 'put' | 'patch', path: string, body?: object][] = [
  ['get', '/v1/me'],
  ['patch', '/v1/me', { city: 'Chennai' }],
  ['put', '/v1/me/photo', { contentType: 'image/png', base64: PNG.toString('base64') }],
  ['get', '/v1/me/photo'],
  ['post', '/v1/me/vehicles', EV001],
  ['get', '/v1/me/vehicles'],
  ['get', '/v1/me/connected-vehicle'],
  ['post', '/v1/vehicles/verify', EV001],
  ['post', '/v1/charging-sessions/session-1/debit'],
  ['post', '/v1/assistant/ask', { message: 'What is regenerative braking?' }],
  ...vehicleRoutes,
];

describe('authentication and ownership', () => {
  it.each(allRoutes)('%s %s returns 401 without a token', async (method, path, body) => {
    const response = await request(apiApp())[method](path).send(body);
    expect(response.status).toBe(401);
  });

  it.each(vehicleRoutes)(
    "%s %s returns 404 for another user's vehicle",
    async (method, path, body) => {
      await seedOwners();
      await seedCard('bob', 'EV002', 50_000);
      const response = await request(apiApp())[method](path).set(bearer('alice')).send(body);
      expect(response.status).toBe(404);
      expect(response.body.error.code).toBe('vehicle_not_found');
    },
  );

  it("does not change another user's data through the ownership check", async () => {
    await seedOwners();
    await request(apiApp())
      .patch('/v1/vehicles/EV002/configuration')
      .set(bearer('alice'))
      .send({ maximumRangeKm: 1, connectorType: 'hacked' });
    expect((await Vehicle.findById('EV002').lean())?.connectorType).toBe('');
  });
});

describe('profile', () => {
  beforeEach(seedOwners);

  it('reads and updates the profile, ignoring nothing silently', async () => {
    const app = apiApp();
    const missing = await request(app).get('/v1/me').set(bearer('nobody'));
    expect(missing.status).toBe(404);
    expect(missing.body.error.code).toBe('profile_not_found');
    const me = await request(app).get('/v1/me').set(bearer('alice'));
    expect(me.body).not.toHaveProperty('passwordHash');

    const updated = await request(app).patch('/v1/me').set(bearer('alice')).send({
      name: 'Alice K',
      phone: '+91 98765 43210',
      city: 'Chennai',
      dateOfBirth: '2000-05-01',
      distanceUnit: 'mi',
    });
    expect(updated.status).toBe(200);
    expect(updated.body).toMatchObject({
      uid: 'alice',
      name: 'Alice K',
      city: 'Chennai',
      distanceUnit: 'mi',
      vehicleId: 'EV001',
    });
    expect(updated.body.dateOfBirth).toMatch(/^2000-05-01/);

    const forbidden = await request(app)
      .patch('/v1/me')
      .set(bearer('alice'))
      .send({ email: 'x@y.com' });
    expect(forbidden.status).toBe(400);
    const vehicleSwap = await request(app)
      .patch('/v1/me')
      .set(bearer('alice'))
      .send({ vehicleId: 'EV002' });
    expect(vehicleSwap.status).toBe(400);
    expect((await request(app).get('/v1/me').set(bearer('alice'))).body.email).toBe(
      'alice@example.com',
    );
  });

  it('stores a JPEG or PNG photo and rejects fakes and oversized files', async () => {
    const app = apiApp();
    const saved = await request(app)
      .put('/v1/me/photo')
      .set(bearer('alice'))
      .send({ contentType: 'image/jpeg', base64: JPEG.toString('base64') });
    expect(saved.status).toBe(200);
    expect(saved.body.profileImageUrl).toMatch(/^\/v1\/me\/photo\?v=\d+$/);

    const photo = await request(app).get('/v1/me/photo').set(bearer('alice'));
    expect(photo.status).toBe(200);
    expect(photo.headers['content-type']).toBe('image/jpeg');
    expect(Buffer.compare(photo.body as Buffer, JPEG)).toBe(0);

    const fake = await request(app)
      .put('/v1/me/photo')
      .set(bearer('alice'))
      .send({
        contentType: 'image/png',
        base64: Buffer.from('<svg onload=alert(1)>').toString('base64'),
      });
    expect(fake.status).toBe(400);
    expect(fake.body.error.code).toBe('photo_invalid_type');

    const big = Buffer.concat([PNG, Buffer.alloc(300 * 1024)]);
    const oversized = await request(app)
      .put('/v1/me/photo')
      .set(bearer('alice'))
      .send({ contentType: 'image/png', base64: big.toString('base64') });
    expect(oversized.status).toBe(400);
  });
});

describe('vehicles', () => {
  beforeEach(seedOwners);

  it('lists, links and switches only owned vehicles', async () => {
    const app = apiApp();
    await Vehicle.create({
      _id: 'EV003',
      registrationNumber: 'TN03EF9012',
      model: 'EV Smart X3',
      ownerName: 'Owner 3',
      vin: 'EVVIN003',
    });
    const linked = await request(app).post('/v1/me/vehicles').set(bearer('alice')).send({
      registrationNumber: 'TN03EF9012',
      model: 'ev smart x3',
      ownerName: 'Owner 3',
      vin: 'evvin003',
    });
    expect(linked.status).toBe(201);

    const list = await request(app).get('/v1/me/vehicles').set(bearer('alice'));
    expect(list.body.vehicles.map((v: { id: string }) => v.id)).toEqual(['EV001', 'EV003']);

    const switched = await request(app)
      .put('/v1/me/connected-vehicle')
      .set(bearer('alice'))
      .send({ vehicleId: 'EV003' });
    expect(switched.body).toEqual({ vehicleId: 'EV003' });
    const connected = await request(app).get('/v1/me/connected-vehicle').set(bearer('alice'));
    expect(connected.body.vehicle.id).toBe('EV003');

    const stolen = await request(app).post('/v1/me/vehicles').set(bearer('alice')).send(EV002);
    expect(stolen.status).toBe(409);
    expect(stolen.body.error.code).toBe('vehicle_already_claimed');
  });

  it('verifies details against the connected vehicle only', async () => {
    const app = apiApp();
    const match = await request(app).post('/v1/vehicles/verify').set(bearer('alice')).send(EV001);
    expect(match.body.vehicle.id).toBe('EV001');
    const other = await request(app).post('/v1/vehicles/verify').set(bearer('alice')).send(EV002);
    expect(other.body.vehicle).toBeNull();
  });

  it('returns metadata only, never live measurements', async () => {
    const response = await request(apiApp()).get('/v1/vehicles/EV001').set(bearer('alice'));
    expect(response.status).toBe(200);
    expect(response.body).toMatchObject({ id: 'EV001', maximumRangeKm: 420 });
    for (const live of [
      'batteryPercentage',
      'battery',
      'speed',
      'health',
      'telemetry',
      'ownerUid',
    ]) {
      expect(response.body).not.toHaveProperty(live);
    }
  });

  it('updates configuration and syncs the card snapshot', async () => {
    await seedCard('alice', 'EV001');
    await ChargingCard.updateOne({ uid: 'alice' }, { vehicleModel: 'stale' });
    const response = await request(apiApp())
      .patch('/v1/vehicles/EV001/configuration')
      .set(bearer('alice'))
      .send({ maximumRangeKm: 450.5, batteryCapacityKwh: 60, connectorType: 'CCS2' });
    expect(response.status).toBe(200);
    expect(response.body).toMatchObject({
      maximumRangeKm: 450.5,
      batteryCapacityKwh: 60,
      connectorType: 'CCS2',
    });
    expect((await ChargingCard.findOne({ uid: 'alice' }).lean())?.vehicleModel).toBe('EV Smart X1');

    const bad = await request(apiApp())
      .patch('/v1/vehicles/EV001/configuration')
      .set(bearer('alice'))
      .send({ maximumRangeKm: 0, connectorType: 'CCS2' });
    expect(bad.status).toBe(400);
    const extra = await request(apiApp())
      .patch('/v1/vehicles/EV001/configuration')
      .set(bearer('alice'))
      .send({ maximumRangeKm: 400, connectorType: 'CCS2', ownerUid: 'alice' });
    expect(extra.status).toBe(400);
  });

  it('adds and lists maintenance records newest first, with cost in rupees', async () => {
    const app = apiApp();
    for (const [serviceDate, cost] of [
      ['2026-01-10', 1500.5],
      ['2026-03-01', null],
    ] as const) {
      const created = await request(app)
        .post('/v1/vehicles/EV001/maintenance')
        .set(bearer('alice'))
        .send({
          serviceType: 'Brake check',
          category: 'Brakes',
          serviceDate,
          cost,
          odometerKm: 12000,
        });
      expect(created.status).toBe(201);
    }
    const list = await request(app).get('/v1/vehicles/EV001/maintenance').set(bearer('alice'));
    expect(list.body.records).toHaveLength(2);
    expect(list.body.records[0].serviceDate).toMatch(/^2026-03-01/);
    expect(list.body.records[1]).toMatchObject({
      cost: 1500.5,
      status: 'Completed',
      source: 'user_entered',
    });

    const negative = await request(app)
      .post('/v1/vehicles/EV001/maintenance')
      .set(bearer('alice'))
      .send({ serviceType: 'X', category: 'Y', serviceDate: '2026-01-01', cost: -5 });
    expect(negative.status).toBe(400);
  });

  it('returns default controls preferences, then saves and reloads them', async () => {
    const app = apiApp();
    const defaults = await request(app)
      .get('/v1/vehicles/EV001/controls-preferences')
      .set(bearer('alice'));
    expect(defaults.body.preferences).toMatchObject({
      notificationsEnabled: true,
      passengerProfiles: [],
      selectedProfileId: null,
    });

    const saved = await request(app)
      .put('/v1/vehicles/EV001/controls-preferences')
      .set(bearer('alice'))
      .send({ preferences: validPreferences });
    expect(saved.status).toBe(200);
    const reloaded = await request(app)
      .get('/v1/vehicles/EV001/controls-preferences')
      .set(bearer('alice'));
    expect(reloaded.body.preferences).toMatchObject({
      safetyAlertsEnabled: false,
      selectedProfileId: 'p1',
      activeAlertKeys: ['lowBattery'],
    });
    expect(reloaded.body.preferences.passengerProfiles[0]).toMatchObject({
      name: 'Driver',
      preferredTemperatureC: 22,
    });

    const tooMany = await request(app)
      .put('/v1/vehicles/EV001/controls-preferences')
      .set(bearer('alice'))
      .send({
        preferences: {
          ...validPreferences,
          activeAlertKeys: Array.from({ length: 33 }, (_, i) => `k${i}`),
        },
      });
    expect(tooMany.status).toBe(400);
  });

  it('keeps alert acknowledgements and still accepts older alert records', async () => {
    const app = apiApp();
    const oldAlert = {
      id: 'EV001_battery_low_3',
      kind: 'battery_low',
      title: 'Battery running low',
      message: 'Battery is below 20%.',
      severity: 'warning',
      timestamp: '2026-10-25T09:00:00.000Z',
    };
    const acknowledged = {
      ...oldAlert,
      id: 'EV001_motor_overheating_critical_9',
      kind: 'motor_overheating_critical',
      severity: 'critical',
      value: '112 °C',
      vehicleId: 'EV001',
      shownAt: '2026-10-25T09:00:01.000Z',
      acknowledgedAt: '2026-10-25T09:00:07.000Z',
    };
    const saved = await request(app)
      .put('/v1/vehicles/EV001/controls-preferences')
      .set(bearer('alice'))
      .send({ preferences: { ...validPreferences, alertHistory: [acknowledged, oldAlert] } });
    expect(saved.status).toBe(200);

    const reloaded = await request(app)
      .get('/v1/vehicles/EV001/controls-preferences')
      .set(bearer('alice'));
    expect(reloaded.body.preferences.alertHistory).toEqual([acknowledged, oldAlert]);

    const tooLong = await request(app)
      .put('/v1/vehicles/EV001/controls-preferences')
      .set(bearer('alice'))
      .send({
        preferences: {
          ...validPreferences,
          alertHistory: [{ ...acknowledged, value: 'x'.repeat(65) }],
        },
      });
    expect(tooLong.status).toBe(400);
  });
});

describe('charging card', () => {
  beforeEach(seedOwners);

  it('registers with only the last four digits and a zero balance', async () => {
    const app = apiApp();
    expect(
      (await request(app).get('/v1/vehicles/EV001/charging-card').set(bearer('alice'))).body,
    ).toEqual({ card: null });

    const created = await request(app)
      .post('/v1/vehicles/EV001/charging-card')
      .set(bearer('alice'))
      .send(cardBody);
    expect(created.status).toBe(201);
    expect(created.body.card).toMatchObject({
      maskedCardNumber: 'XXXX XXXX XXXX 1234',
      balance: 0,
      currency: 'INR',
      status: 'ACTIVE',
      vehicleModel: 'EV Smart X1',
      vehicleRegistrationNumber: 'TN01AB1234',
    });
    const duplicate = await request(app)
      .post('/v1/vehicles/EV001/charging-card')
      .set(bearer('alice'))
      .send(cardBody);
    expect(duplicate.status).toBe(409);
  });

  it('rejects a full card number, CVV, PIN or a forged balance', async () => {
    const app = apiApp();
    for (const extra of [
      { cardNumber: '4111111111111234' },
      { cvv: '123' },
      { pin: '0000' },
      { balance: 5000 },
    ]) {
      const response = await request(app)
        .post('/v1/vehicles/EV001/charging-card')
        .set(bearer('alice'))
        .send({ ...cardBody, ...extra });
      expect(response.status).toBe(400);
    }
    const inconsistent = await request(app)
      .post('/v1/vehicles/EV001/charging-card')
      .set(bearer('alice'))
      .send({ ...cardBody, maskedCardNumber: 'XXXX XXXX XXXX 9999' });
    expect(inconsistent.status).toBe(400);
    expect(await ChargingCard.countDocuments()).toBe(0);
  });

  it('updates card details but never balance, status or currency', async () => {
    const app = apiApp();
    await seedCard('alice', 'EV001', 10_000);
    const updated = await request(app)
      .patch('/v1/vehicles/EV001/charging-card')
      .set(bearer('alice'))
      .send({
        cardType: 'Fleet card',
        cardHolderName: 'Alice K',
        expiryDate: '2031-06-30',
        cardLastFour: '9876',
        maskedCardNumber: 'XXXX XXXX XXXX 9876',
      });
    expect(updated.status).toBe(200);
    expect(updated.body.card).toMatchObject({
      cardType: 'Fleet card',
      maskedCardNumber: 'XXXX XXXX XXXX 9876',
      balance: 100,
    });

    for (const extra of [{ balance: 1 }, { status: 'BLOCKED' }, { currency: 'USD' }]) {
      const response = await request(app)
        .patch('/v1/vehicles/EV001/charging-card')
        .set(bearer('alice'))
        .send({ cardType: 'X', cardHolderName: 'Y', expiryDate: '2031-01-01', ...extra });
      expect(response.status).toBe(400);
    }
    expect((await ChargingCard.findOne({ uid: 'alice' }).lean())?.balancePaise).toBe(10_000);
  });

  it('lists transactions newest first with the requested limit', async () => {
    const card = await seedCard('alice', 'EV001');
    await CardTransaction.create(
      [1, 2, 3].map((day) => ({
        cardId: card._id,
        uid: 'alice',
        vehicleId: 'EV001',
        type: 'credit' as const,
        amountPaise: day * 100,
        balanceBeforePaise: 0,
        balanceAfterPaise: day * 100,
        currency: 'INR',
        timestamp: new Date(`2026-01-0${day}T00:00:00Z`),
      })),
    );
    const response = await request(apiApp())
      .get('/v1/vehicles/EV001/charging-card/transactions?limit=2')
      .set(bearer('alice'));
    expect(response.status).toBe(200);
    expect(response.body.transactions.map((t: { amount: number }) => t.amount)).toEqual([3, 2]);
    const badLimit = await request(apiApp())
      .get('/v1/vehicles/EV001/charging-card/transactions?limit=1000')
      .set(bearer('alice'));
    expect(badLimit.status).toBe(400);
  });
});

describe('charging-session debit', () => {
  beforeEach(async () => {
    await seedOwners();
    await ChargingSession.create({
      _id: 'session-1',
      uid: 'alice',
      vehicleId: 'EV001',
      stationId: 'station-9',
      stationName: 'City Fast Charge',
      operator: 'ChargeCo',
      amountPaise: 25_000,
      confirmedAt: new Date('2026-10-08T10:00:00Z'),
    });
  });

  it('debits a confirmed session atomically and only once', async () => {
    await seedCard('alice', 'EV001', 100_000);
    const app = apiApp();
    const first = await request(app)
      .post('/v1/charging-sessions/session-1/debit')
      .set(bearer('alice'));
    expect(first.status).toBe(200);
    expect(first.body).toMatchObject({
      alreadyDebited: false,
      vehicleId: 'EV001',
      balanceBefore: 1000,
      balanceAfter: 750,
    });

    const second = await request(app)
      .post('/v1/charging-sessions/session-1/debit')
      .set(bearer('alice'));
    expect(second.body).toMatchObject({
      alreadyDebited: true,
      balanceAfter: 750,
      transactionId: first.body.transactionId,
    });

    expect((await ChargingCard.findOne({ uid: 'alice' }).lean())?.balancePaise).toBe(75_000);
    const transactions = await CardTransaction.find({ sessionReferenceId: 'session-1' }).lean();
    expect(transactions).toHaveLength(1);
    expect(transactions[0]).toMatchObject({
      type: 'debit',
      amountPaise: 25_000,
      stationName: 'City Fast Charge',
    });
    expect((await ChargingSession.findById('session-1').lean())?.debitStatus).toBe('completed');
  });

  it('leaves the balance and session unchanged when funds are insufficient', async () => {
    await seedCard('alice', 'EV001', 10_000);
    const response = await request(apiApp())
      .post('/v1/charging-sessions/session-1/debit')
      .set(bearer('alice'));
    expect(response.status).toBe(409);
    expect(response.body.error).toEqual({
      code: 'insufficient_balance',
      message: 'Insufficient charging card balance.',
    });
    expect((await ChargingCard.findOne({ uid: 'alice' }).lean())?.balancePaise).toBe(10_000);
    expect((await ChargingSession.findById('session-1').lean())?.debitStatus).toBe('pending');
    expect(await CardTransaction.countDocuments()).toBe(0);
  });

  it("cannot debit another user's session", async () => {
    await seedCard('bob', 'EV002', 100_000);
    const response = await request(apiApp())
      .post('/v1/charging-sessions/session-1/debit')
      .set(bearer('bob'));
    expect(response.status).toBe(404);
    expect((await ChargingSession.findById('session-1').lean())?.debitStatus).toBe('pending');
  });

  it('rejects an untrusted session', async () => {
    await seedCard('alice', 'EV001', 100_000);
    await ChargingSession.updateOne({ _id: 'session-1' }, { status: 'requested' });
    const response = await request(apiApp())
      .post('/v1/charging-sessions/session-1/debit')
      .set(bearer('alice'));
    expect(response.status).toBe(409);
    expect((await ChargingCard.findOne({ uid: 'alice' }).lean())?.balancePaise).toBe(100_000);
  });
});
