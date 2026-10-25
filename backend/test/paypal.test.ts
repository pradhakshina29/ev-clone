// Ported from the original PayPal recharge tests.
import request from 'supertest';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { CardTransaction } from '../src/models/cardTransaction.js';
import { ChargingCard } from '../src/models/chargingCard.js';
import { PaypalOrder } from '../src/models/paypalOrder.js';
import { convertInrToUsdCents } from '../src/services/paypal.js';
import {
  apiApp,
  DEMO_RATE,
  fakeFetch,
  jsonResponse,
  PAYPAL_BASE,
  seedCard,
  seedOwners,
} from './fixtures.js';
import { bearer } from './helpers.js';

beforeAll(async () => {
  await CardTransaction.createIndexes();
  await ChargingCard.createIndexes();
});

const ORDERS = '/v1/vehicles/EV001/charging-card/paypal-orders';

/** A PayPal Sandbox stand-in: one order, captured for `capturedValue` USD. */
function paypalSandbox(
  options: { orderId?: string; capturedValue?: string; captureStatus?: string } = {},
) {
  const orderId = options.orderId ?? 'SANDBOXORDER123';
  let captureCalls = 0;
  const sandbox = fakeFetch((url) => {
    if (url === `${PAYPAL_BASE}/v1/oauth2/token`)
      return jsonResponse({ access_token: 'test-only-token' });
    if (url === `${PAYPAL_BASE}/v2/checkout/orders`) {
      return jsonResponse({
        id: orderId,
        status: 'CREATED',
        links: [{ rel: 'approve', href: 'https://www.sandbox.paypal.com/checkoutnow?token=x' }],
      });
    }
    if (url === `${PAYPAL_BASE}/v2/checkout/orders/${orderId}/capture`) {
      captureCalls += 1;
      const status = options.captureStatus ?? 'COMPLETED';
      return jsonResponse({
        status,
        purchase_units: [
          {
            payments: {
              captures: [
                {
                  id: 'SANDBOXCAPTURE123',
                  status,
                  amount: { value: options.capturedValue ?? '1.20', currency_code: 'USD' },
                },
              ],
            },
          },
        ],
      });
    }
    throw new Error(`Unexpected PayPal test URL: ${url}`);
  });
  return { ...sandbox, captureCalls: () => captureCalls };
}

beforeEach(seedOwners);

describe('PayPal recharge', () => {
  it('fixed demo conversion maps the INR presets to USD cents', () => {
    for (const [inr, cents] of [
      [100, 120],
      [250, 300],
      [500, 600],
      [1000, 1200],
    ] as const) {
      expect(convertInrToUsdCents(inr * 100, DEMO_RATE)).toBe(cents);
    }
  });

  it('creates and captures a sandbox order, crediting the card exactly once', async () => {
    await seedCard('alice', 'EV001', 2_500);
    const sandbox = paypalSandbox();
    const app = apiApp({ paypalFetch: sandbox.fetch });

    const order = await request(app).post(ORDERS).set(bearer('alice')).send({ amountInr: 100 });
    expect(order.status).toBe(201);
    expect(order.body).toMatchObject({
      success: true,
      orderId: 'SANDBOXORDER123',
      approvalUrl: 'https://www.sandbox.paypal.com/checkoutnow?token=x',
      amount: 100,
      currency: 'INR',
      paypalAmount: 1.2,
      paypalCurrency: 'USD',
      conversionType: 'demo_fixed_rate',
      demoExchangeRate: DEMO_RATE,
      currentBalance: 25,
      paypalClientId: 'test-only-client-id',
    });
    expect(order.body).not.toHaveProperty('paypalClientSecret');
    // The OAuth call sends the credentials only to PayPal.
    expect(sandbox.requests[0]?.url).toBe(`${PAYPAL_BASE}/v1/oauth2/token`);

    const capture = () =>
      request(app).post(`${ORDERS}/SANDBOXORDER123/capture`).set(bearer('alice'));
    const first = await capture();
    expect(first.status).toBe(200);
    expect(first.body).toMatchObject({
      success: true,
      balanceBefore: 25,
      balanceAfter: 125,
      amount: 100,
      paypalAmount: 1.2,
    });

    const second = await capture();
    expect(second.status).toBe(200);
    expect(second.body).toMatchObject({
      alreadyCaptured: true,
      balanceAfter: 125,
      transactionId: first.body.transactionId,
    });

    expect(sandbox.captureCalls()).toBe(1);
    expect((await ChargingCard.findOne({ uid: 'alice' }).lean())?.balancePaise).toBe(12_500);
    const credits = await CardTransaction.find({ paypalOrderId: 'SANDBOXORDER123' }).lean();
    expect(credits).toHaveLength(1);
    expect(credits[0]).toMatchObject({
      type: 'credit',
      amountPaise: 10_000,
      paypalAmountCents: 120,
      paypalCaptureId: 'SANDBOXCAPTURE123',
    });
    expect((await PaypalOrder.findById('SANDBOXORDER123').lean())?.status).toBe('COMPLETED');

    const history = await request(app)
      .get('/v1/vehicles/EV001/charging-card/transactions')
      .set(bearer('alice'));
    expect(history.body.transactions[0]).toMatchObject({
      type: 'credit',
      amount: 100,
      paymentProvider: 'PayPal Sandbox',
      paypalAmount: 1.2,
    });
  });

  it('concurrent captures of the same order still credit once', async () => {
    await seedCard('alice', 'EV001', 0);
    const app = apiApp({ paypalFetch: paypalSandbox().fetch });
    await request(app).post(ORDERS).set(bearer('alice')).send({ amountInr: 100 });
    const results = await Promise.all(
      [1, 2, 3].map(() =>
        request(app).post(`${ORDERS}/SANDBOXORDER123/capture`).set(bearer('alice')),
      ),
    );
    for (const result of results) expect(result.status).toBe(200);
    expect((await ChargingCard.findOne({ uid: 'alice' }).lean())?.balancePaise).toBe(10_000);
    expect(await CardTransaction.countDocuments({ paypalOrderId: 'SANDBOXORDER123' })).toBe(1);
  });

  it('sends the exact USD 12.00 body to PayPal for a ₹1000 order', async () => {
    await seedCard('alice', 'EV001', 100_000);
    const sandbox = paypalSandbox({ orderId: 'SANDBOXORDER1000' });
    const response = await request(apiApp({ paypalFetch: sandbox.fetch }))
      .post(ORDERS)
      .set(bearer('alice'))
      .send({ amountInr: 1000 });
    expect(response.status).toBe(201);
    const orderRequest = sandbox.requests.find(
      (r) => r.url === `${PAYPAL_BASE}/v2/checkout/orders`,
    );
    const sent = JSON.parse(String(orderRequest?.init?.body)) as {
      purchase_units: { amount: unknown }[];
    };
    expect(sent.purchase_units[0]?.amount).toEqual({ currency_code: 'USD', value: '12.00' });
    expect(response.body).toMatchObject({ amount: 1000, paypalAmount: 12 });
  });

  it('returns to the app through deep links only when the app asks for it', async () => {
    await seedCard('alice', 'EV001');
    const contexts: Record<string, unknown>[] = [];
    for (const body of [{ amountInr: 100, returnTo: 'app' }, { amountInr: 100 }]) {
      const sandbox = paypalSandbox({ orderId: `ORDER${contexts.length}` });
      const response = await request(apiApp({ paypalFetch: sandbox.fetch }))
        .post(ORDERS)
        .set(bearer('alice'))
        .send(body);
      expect(response.status).toBe(201);
      const sent = sandbox.requests.find((r) => r.url === `${PAYPAL_BASE}/v2/checkout/orders`);
      contexts.push(
        (JSON.parse(String(sent?.init?.body)) as { application_context: Record<string, unknown> })
          .application_context,
      );
    }
    expect(contexts[0]).toMatchObject({
      return_url: 'evsmartcompanion://paypal-return',
      cancel_url: 'evsmartcompanion://paypal-cancel',
    });
    expect(contexts[1]).toMatchObject({ return_url: 'https://example.com/paypal-return' });

    const invalid = await request(apiApp({ paypalFetch: paypalSandbox().fetch }))
      .post(ORDERS)
      .set(bearer('alice'))
      .send({ amountInr: 100, returnTo: 'https://evil.example' });
    expect(invalid.status).toBe(400);
  });

  it('reports an unapproved order as not approved and credits nothing', async () => {
    await seedCard('alice', 'EV001', 5_000);
    const created = paypalSandbox({ orderId: 'UNAPPROVED1' });
    await request(apiApp({ paypalFetch: created.fetch }))
      .post(ORDERS)
      .set(bearer('alice'))
      .send({ amountInr: 100, returnTo: 'app' });
    const notApproved = fakeFetch((url) =>
      url.endsWith('/v1/oauth2/token')
        ? jsonResponse({ access_token: 'test-only-token' })
        : jsonResponse(
            { name: 'UNPROCESSABLE_ENTITY', details: [{ issue: 'ORDER_NOT_APPROVED' }] },
            422,
          ),
    );
    const response = await request(apiApp({ paypalFetch: notApproved.fetch }))
      .post(`${ORDERS}/UNAPPROVED1/capture`)
      .set(bearer('alice'));
    expect(response.status).toBe(409);
    expect(response.body.error.code).toBe('paypal_not_approved');
    expect((await ChargingCard.findOne({ uid: 'alice' }).lean())?.balancePaise).toBe(5_000);
    expect(await CardTransaction.countDocuments()).toBe(0);
    // The order stays pending, so paying afterwards can still be captured.
    expect((await PaypalOrder.findById('UNAPPROVED1').lean())?.status).toBe('PENDING');
  });

  it('never forwards raw PayPal errors to the app', async () => {
    await seedCard('alice', 'EV001');
    const paypal = fakeFetch((url) =>
      url.endsWith('/v1/oauth2/token')
        ? jsonResponse({ access_token: 'test-only-token' })
        : jsonResponse(
            {
              name: 'UNPROCESSABLE_ENTITY',
              details: [
                {
                  issue: 'INVALID_CURRENCY_CODE',
                  field: '/purchase_units/0',
                  description: 'Internal detail',
                },
              ],
              message: 'Internal PayPal message',
              debug_id: 'SAFE-DEBUG-ID',
            },
            422,
          ),
    );
    const response = await request(apiApp({ paypalFetch: paypal.fetch }))
      .post(ORDERS)
      .set(bearer('alice'))
      .send({ amountInr: 100 });
    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('paypal_rejected');
    const text = JSON.stringify(response.body);
    for (const leaked of ['Internal', 'INVALID_CURRENCY_CODE', 'test-only'])
      expect(text).not.toContain(leaked);
    expect(await PaypalOrder.countDocuments()).toBe(0);
  });

  it('rejects invalid and excessive amounts before contacting PayPal', async () => {
    await seedCard('alice', 'EV001');
    const paypal = fakeFetch(() => {
      throw new Error('PayPal must not be contacted');
    });
    const app = apiApp({ paypalFetch: paypal.fetch });
    for (const amountInr of [0, -5, 10_000.01, 10.123]) {
      const response = await request(app).post(ORDERS).set(bearer('alice')).send({ amountInr });
      expect(response.status).toBe(400);
    }
    const asString = await request(app)
      .post(ORDERS)
      .set(bearer('alice'))
      .send({ amountInr: '100' });
    expect(asString.status).toBe(400);
    expect(paypal.requests).toHaveLength(0);
  });

  it('requires an INR charging card for the demo conversion', async () => {
    const card = await seedCard('alice', 'EV001');
    await ChargingCard.updateOne({ _id: card._id }, { currency: 'USD' });
    const paypal = fakeFetch(() => {
      throw new Error('PayPal must not be contacted');
    });
    const response = await request(apiApp({ paypalFetch: paypal.fetch }))
      .post(ORDERS)
      .set(bearer('alice'))
      .send({ amountInr: 100 });
    expect(response.status).toBe(400);
    expect(paypal.requests).toHaveLength(0);
  });

  it("cannot capture another user's order", async () => {
    await seedCard('alice', 'EV001');
    await seedCard('bob', 'EV002');
    const sandbox = paypalSandbox();
    const app = apiApp({ paypalFetch: sandbox.fetch });
    await request(app).post(ORDERS).set(bearer('alice')).send({ amountInr: 100 });

    const asBobOnAlicesVehicle = await request(app)
      .post(`${ORDERS}/SANDBOXORDER123/capture`)
      .set(bearer('bob'));
    expect(asBobOnAlicesVehicle.status).toBe(404);
    const asBobOnOwnVehicle = await request(app)
      .post('/v1/vehicles/EV002/charging-card/paypal-orders/SANDBOXORDER123/capture')
      .set(bearer('bob'));
    expect(asBobOnOwnVehicle.status).toBe(404);
    expect(sandbox.captureCalls()).toBe(0);
    expect((await ChargingCard.findOne({ uid: 'bob' }).lean())?.balancePaise).toBe(0);
  });

  it('a pending or mismatched capture never changes the balance', async () => {
    await seedCard('alice', 'EV001', 5_000);
    for (const options of [{ captureStatus: 'PENDING' }, { capturedValue: '0.01' }]) {
      await PaypalOrder.deleteMany({});
      const app = apiApp({ paypalFetch: paypalSandbox(options).fetch });
      await request(app).post(ORDERS).set(bearer('alice')).send({ amountInr: 100 });
      const response = await request(app)
        .post(`${ORDERS}/SANDBOXORDER123/capture`)
        .set(bearer('alice'));
      expect(response.status).toBe(409);
      expect((await ChargingCard.findOne({ uid: 'alice' }).lean())?.balancePaise).toBe(5_000);
      expect((await PaypalOrder.findById('SANDBOXORDER123').lean())?.status).toBe('PENDING');
    }
    expect(await CardTransaction.countDocuments()).toBe(0);
  });
});
