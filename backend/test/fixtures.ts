import bcrypt from 'bcryptjs';

import { createApp } from '../src/app.js';
import { ChargingCard } from '../src/models/chargingCard.js';
import { User } from '../src/models/user.js';
import { Vehicle } from '../src/models/vehicle.js';
import { createRouters } from '../src/routes/index.js';
import { fakeVerifier } from './helpers.js';

export const PAYPAL_BASE = 'https://api-m.sandbox.paypal.com';
export const DEMO_RATE = 0.012;

export type RecordedRequest = { url: string; init: RequestInit | undefined };
type Handler = (url: string, init: RequestInit | undefined) => Response | Promise<Response>;

/** A fetch stand-in that records requests and answers from the given handler. */
export function fakeFetch(handler: Handler) {
  const requests: RecordedRequest[] = [];
  const fn = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    requests.push({ url, init });
    return handler(url, init);
  }) as typeof fetch;
  return { fetch: fn, requests };
}

export function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const unexpected: Handler = (url) => {
  throw new Error(`Unexpected outbound request in test: ${url}`);
};

export function apiApp(
  options: {
    paypalFetch?: typeof fetch;
    geminiFetch?: typeof fetch;
    geminiKey?: string;
    geminiFallbackModel?: string;
    geoFetch?: typeof fetch;
  } = {},
) {
  return createApp({
    nodeEnv: 'test',
    corsOrigins: ['http://localhost:5100'],
    verifyIdToken: fakeVerifier,
    routers: createRouters({
      paypal: {
        clientId: 'test-only-client-id',
        clientSecret: 'test-only-client-secret',
        apiBase: PAYPAL_BASE,
        demoExchangeRateInrToUsd: DEMO_RATE,
        fetch: options.paypalFetch ?? fakeFetch(unexpected).fetch,
      },
      assistant: {
        apiKey: options.geminiKey ?? 'test-only-gemini-key',
        model: 'gemini-flash-latest',
        fallbackModel: options.geminiFallbackModel,
        fetch: options.geminiFetch ?? fakeFetch(unexpected).fetch,
      },
      geo: { fetch: options.geoFetch ?? fakeFetch(unexpected).fetch },
    }),
  });
}

export const EV001 = {
  registrationNumber: 'TN01AB1234',
  model: 'EV Smart X1',
  ownerName: 'Registered Vehicle Owner 1',
  vin: 'EVVIN001',
};
export const EV002 = {
  registrationNumber: 'TN02CD5678',
  model: 'EV Smart X2',
  ownerName: 'Registered Vehicle Owner 2',
  vin: 'EVVIN002',
};

export async function seedVehicles() {
  await Vehicle.create([
    { _id: 'EV001', ...EV001, bluetoothDeviceName: 'EV-Simulator-01', maximumRangeKm: 420 },
    { _id: 'EV002', ...EV002, bluetoothDeviceName: 'EV-Simulator-02', maximumRangeKm: 380 },
  ]);
}

export const TEST_PASSWORD = 'Password1';
const testPasswordHash = bcrypt.hashSync(TEST_PASSWORD, 4);

/** Alice owns EV001, Bob owns EV002; both use TEST_PASSWORD. */
export async function seedOwners() {
  await seedVehicles();
  await Vehicle.updateOne({ _id: 'EV001' }, { ownerUid: 'alice' });
  await Vehicle.updateOne({ _id: 'EV002' }, { ownerUid: 'bob' });
  await User.create([
    {
      _id: 'alice',
      name: 'Alice',
      email: 'alice@example.com',
      passwordHash: testPasswordHash,
      vehicleId: 'EV001',
      vehicleRegistrationNumber: EV001.registrationNumber,
    },
    {
      _id: 'bob',
      name: 'Bob',
      email: 'bob@example.com',
      passwordHash: testPasswordHash,
      vehicleId: 'EV002',
      vehicleRegistrationNumber: EV002.registrationNumber,
    },
  ]);
}

export async function seedCard(uid: string, vehicleId: string, balancePaise = 0) {
  return ChargingCard.create({
    uid,
    vehicleId,
    cardType: 'EV Charging Card',
    maskedCardNumber: 'XXXX XXXX XXXX 1234',
    cardLastFour: '1234',
    cardHolderName: 'Card Holder',
    expiryDate: new Date('2030-01-01T00:00:00Z'),
    balancePaise,
  });
}
