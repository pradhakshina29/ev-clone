import request from 'supertest';
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

import { CardTransaction } from '../src/models/cardTransaction.js';
import { ChargingCard } from '../src/models/chargingCard.js';
import { Counter, Invoice } from '../src/models/invoice.js';
import { apiApp, fakeFetch, jsonResponse, PAYPAL_BASE, seedCard, seedOwners } from './fixtures.js';
import { bearer } from './helpers.js';

beforeAll(async () => {
  await CardTransaction.createIndexes();
  await ChargingCard.createIndexes();
  await Invoice.createIndexes();
});

beforeEach(seedOwners);

const CARD = '/v1/vehicles/EV001/charging-card';

function paypalSandbox() {
  return fakeFetch((url) => {
    if (url === `${PAYPAL_BASE}/v1/oauth2/token`)
      return jsonResponse({ access_token: 'test-only-token' });
    if (url === `${PAYPAL_BASE}/v2/checkout/orders`) {
      return jsonResponse({
        id: 'SANDBOXORDER123',
        status: 'CREATED',
        links: [{ rel: 'approve', href: 'https://www.sandbox.paypal.com/checkoutnow?token=x' }],
      });
    }
    if (url === `${PAYPAL_BASE}/v2/checkout/orders/SANDBOXORDER123/capture`) {
      return jsonResponse({
        status: 'COMPLETED',
        purchase_units: [
          {
            payments: {
              captures: [
                {
                  id: 'SANDBOXCAPTURE123',
                  status: 'COMPLETED',
                  amount: { value: '1.20', currency_code: 'USD' },
                },
              ],
            },
          },
        ],
      });
    }
    throw new Error(`Unexpected PayPal test URL: ${url}`);
  });
}

/** Runs a verified ₹100 sandbox recharge for Alice and returns the capture body. */
async function rechargeAlice(app = apiApp({ paypalFetch: paypalSandbox().fetch })) {
  await seedCard('alice', 'EV001', 0);
  await request(app)
    .post(`${CARD}/paypal-orders`)
    .set(bearer('alice'))
    .send({ amountInr: 100 })
    .expect(201);
  const capture = await request(app)
    .post(`${CARD}/paypal-orders/SANDBOXORDER123/capture`)
    .set(bearer('alice'))
    .expect(200);
  return { app, capture: capture.body as { transactionId: string; invoiceNumber: string | null } };
}

describe('payment receipts', () => {
  it('creates exactly one receipt for a verified recharge, with verified data', async () => {
    const { app, capture } = await rechargeAlice();
    const year = new Date().getUTCFullYear();
    expect(capture.invoiceNumber).toBe(`EVSC-TEST-${year}-000001`);

    // Repeated capture callbacks and downloads reuse the same receipt.
    await request(app)
      .post(`${CARD}/paypal-orders/SANDBOXORDER123/capture`)
      .set(bearer('alice'))
      .expect(200);
    for (let i = 0; i < 2; i++) {
      const response = await request(app)
        .get(`${CARD}/transactions/${capture.transactionId}/invoice`)
        .set(bearer('alice'));
      expect(response.status).toBe(200);
      expect(response.body.invoice).toMatchObject({
        invoiceNumber: capture.invoiceNumber,
        transactionId: capture.transactionId,
        paypalCaptureId: 'SANDBOXCAPTURE123',
        amount: 100,
        currency: 'INR',
        paypalAmount: 1.2,
        paypalCurrency: 'USD',
        status: 'PAID',
        sandbox: true,
      });
    }
    expect(await Invoice.countDocuments()).toBe(1);
    expect(await CardTransaction.countDocuments()).toBe(1);
    const stored = await Invoice.findOne().lean();
    expect(JSON.stringify(stored)).not.toMatch(/secret|token|clientId/i);
  });

  it('serves the PDF only to the owner, uncached', async () => {
    const { app, capture } = await rechargeAlice();
    const pdfPath = `${CARD}/transactions/${capture.transactionId}/invoice.pdf`;
    const response = await request(app)
      .get(pdfPath)
      .set(bearer('alice'))
      .buffer(true)
      .parse((res, done) => {
        const chunks: Buffer[] = [];
        res.on('data', (chunk: Buffer) => chunks.push(chunk));
        res.on('end', () => done(null, Buffer.concat(chunks)));
      });
    expect(response.status).toBe(200);
    expect(response.headers['content-type']).toBe('application/pdf');
    expect(response.headers['cache-control']).toBe('private, no-store');
    expect(response.headers['content-disposition']).toContain(`${capture.invoiceNumber}.pdf`);
    const pdf = response.body as Buffer;
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-');

    expect((await request(app).get(pdfPath)).status).toBe(401);
    // Bob does not own EV001: same answer as a missing vehicle.
    expect((await request(app).get(pdfPath).set(bearer('bob'))).status).toBe(404);
    const bobsPath = `/v1/vehicles/EV002/charging-card/transactions/${capture.transactionId}/invoice`;
    const bobs = await request(app).get(bobsPath).set(bearer('bob'));
    expect(bobs.status).toBe(404);
    expect(bobs.body.error.code).toBe('invoice_not_found');
  });

  it('gives no receipt for transactions that are not verified recharges', async () => {
    const app = apiApp();
    const card = await seedCard('alice', 'EV001', 10_000);
    const debit = await CardTransaction.create({
      cardId: card._id,
      uid: 'alice',
      vehicleId: 'EV001',
      type: 'debit',
      amountPaise: 500,
      balanceBeforePaise: 10_000,
      balanceAfterPaise: 9_500,
      currency: 'INR',
      timestamp: new Date(),
    });
    // A credit that claims PayPal but has no completed PayPal order behind it.
    const unverified = await CardTransaction.create({
      cardId: card._id,
      uid: 'alice',
      vehicleId: 'EV001',
      type: 'credit',
      amountPaise: 500,
      balanceBeforePaise: 9_500,
      balanceAfterPaise: 10_000,
      currency: 'INR',
      timestamp: new Date(),
      paypalOrderId: 'NOTCAPTURED',
      paypalCaptureId: 'FAKECAPTURE',
      paypalAmountCents: 6,
      paypalCurrency: 'USD',
    });
    for (const transaction of [debit, unverified]) {
      const response = await request(app)
        .get(`${CARD}/transactions/${transaction._id.toString()}/invoice`)
        .set(bearer('alice'));
      expect(response.status).toBe(409);
      expect(response.body.error.code).toBe('invoice_unavailable');
    }
    const invalid = await request(app)
      .get(`${CARD}/transactions/not-an-id/invoice`)
      .set(bearer('alice'));
    expect(invalid.status).toBe(400);
    expect(await Invoice.countDocuments()).toBe(0);
  });

  it('a receipt failure never fails the capture, and can be retried', async () => {
    const spy = vi.spyOn(Counter, 'findOneAndUpdate').mockImplementationOnce(() => {
      throw new Error('database unavailable');
    });
    const { app, capture } = await rechargeAlice();
    spy.mockRestore();
    expect(capture.transactionId).toBeTruthy();
    expect(capture.invoiceNumber).toBeNull();
    expect((await ChargingCard.findOne({ uid: 'alice' }).lean())?.balancePaise).toBe(10_000);

    const retry = await request(app)
      .get(`${CARD}/transactions/${capture.transactionId}/invoice`)
      .set(bearer('alice'));
    expect(retry.status).toBe(200);
    expect(await Invoice.countDocuments()).toBe(1);
    // The retry did not charge or credit again.
    expect(await CardTransaction.countDocuments()).toBe(1);
  });

  it('concurrent first downloads still create one receipt', async () => {
    const { app, capture } = await rechargeAlice();
    await Invoice.deleteMany({});
    const responses = await Promise.all(
      Array.from({ length: 3 }, () =>
        request(app)
          .get(`${CARD}/transactions/${capture.transactionId}/invoice`)
          .set(bearer('alice')),
      ),
    );
    expect(responses.map((r) => r.status)).toEqual([200, 200, 200]);
    expect(new Set(responses.map((r) => r.body.invoice.invoiceNumber)).size).toBe(1);
    expect(await Invoice.countDocuments()).toBe(1);
  });
});
