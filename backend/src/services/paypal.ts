// Ported from the original backend (createPayPalRechargeOrder,
// capturePayPalRechargeOrder, paypalRequest, throwPayPalApiError).
import { createHash, randomUUID } from 'node:crypto';

import mongoose from 'mongoose';

import { logger } from '../logger.js';
import { HttpError } from '../middleware/errors.js';
import { CardTransaction } from '../models/cardTransaction.js';
import { ChargingCard } from '../models/chargingCard.js';
import { paiseToRupees } from '../models/common.js';
import { PaypalOrder } from '../models/paypalOrder.js';
import { badRequest, conflict, isDuplicateKeyError, notFound } from './errors.js';
import { requireOwnedVehicle } from './vehicles.js';

export const MAX_PAYPAL_RECHARGE_INR = 10_000;
export const PAYPAL_SANDBOX_CURRENCY = 'USD';
export const CONVERSION_TYPE = 'demo_fixed_rate';
const PAYPAL_TIMEOUT_MS = 15_000;

/**
 * Where PayPal sends the payer after approving or cancelling. The Android/iOS
 * app opens checkout in a browser tab and is brought back by these deep
 * links; the web app uses the SDK popup, which ignores them.
 */
export const APP_RETURN_URL = 'evsmartcompanion://paypal-return';
export const APP_CANCEL_URL = 'evsmartcompanion://paypal-cancel';
const WEB_RETURN_URL = 'https://example.com/paypal-return';
const WEB_CANCEL_URL = 'https://example.com/paypal-cancel';

export type RechargeReturnTo = 'app' | 'web';

export type PayPalConfig = {
  clientId: string;
  clientSecret: string;
  apiBase: string;
  demoExchangeRateInrToUsd: number;
  fetch: typeof fetch;
};

type SafeDetail = { issue?: string; field?: string; description?: string };

export class PayPalApiError extends Error {
  constructor(
    readonly operation: string,
    readonly status: number,
    readonly paypalErrorName?: string,
    readonly paypalMessage?: string,
    readonly details: SafeDetail[] = [],
    readonly debugId?: string,
  ) {
    super(`PayPal ${operation} failed with HTTP ${status}.`);
    this.name = 'PayPalApiError';
  }
}

/** Validates a recharge amount in rupees and returns whole paise. */
export function validateRechargeAmount(amountInr: number): number {
  if (!Number.isFinite(amountInr) || amountInr <= 0) {
    throw badRequest('Recharge amount must be greater than zero.');
  }
  if (amountInr > MAX_PAYPAL_RECHARGE_INR) {
    throw badRequest(`Recharge amount cannot exceed ${MAX_PAYPAL_RECHARGE_INR.toFixed(2)}.`);
  }
  if (Math.abs(amountInr * 100 - Math.round(amountInr * 100)) > 1e-7) {
    throw badRequest('Recharge amounts must use no more than two decimals.');
  }
  return Math.round(amountInr * 100);
}

/** Demo-only fixed conversion, same rounding as convertInrToPaypalAmount. */
export function convertInrToUsdCents(amountPaise: number, rate: number): number {
  const usd = Number((paiseToRupees(amountPaise) * rate + Number.EPSILON).toFixed(2));
  return Math.round(usd * 100);
}

const formatCents = (cents: number) => (cents / 100).toFixed(2);

async function toPayPalApiError(operation: string, response: Response): Promise<PayPalApiError> {
  let body: Record<string, unknown> = {};
  try {
    body = (await response.json()) as Record<string, unknown>;
  } catch {
    // PayPal error metadata may be absent; the raw body is never exposed.
  }
  const safeText = (value: unknown) =>
    typeof value === 'string'
      ? value.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 500) // eslint-disable-line no-control-regex
      : undefined;
  const details = Array.isArray(body.details)
    ? body.details
        .filter(
          (detail): detail is Record<string, unknown> => !!detail && typeof detail === 'object',
        )
        .map((detail) => {
          const safe: SafeDetail = {};
          const issue = safeText(detail.issue);
          const field = safeText(detail.field);
          const description = safeText(detail.description);
          if (issue) safe.issue = issue;
          if (field) safe.field = field;
          if (description) safe.description = description;
          return safe;
        })
    : [];
  const error = new PayPalApiError(
    operation,
    response.status,
    safeText(body.name) ?? safeText(body.error),
    safeText(body.message),
    details,
    safeText(body.debug_id),
  );
  logger.error(
    {
      httpStatus: error.status,
      paypalErrorName: error.paypalErrorName,
      paypalMessage: error.paypalMessage,
      details: error.details,
      debugId: error.debugId,
    },
    `PayPal ${operation} failed`,
  );
  return error;
}

async function paypalRequest(
  config: PayPalConfig,
  options: { operation: string; path: string; body: unknown; requestId: string },
): Promise<Record<string, unknown>> {
  const signal = () => AbortSignal.timeout(PAYPAL_TIMEOUT_MS);
  const tokenResponse = await config.fetch(`${config.apiBase}/v1/oauth2/token`, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${Buffer.from(`${config.clientId}:${config.clientSecret}`).toString('base64')}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=client_credentials',
    signal: signal(),
  });
  if (!tokenResponse.ok) throw await toPayPalApiError('OAuth token request', tokenResponse);
  const token = ((await tokenResponse.json()) as { access_token?: unknown }).access_token;
  if (typeof token !== 'string' || !token) {
    throw new Error('PayPal Sandbox did not return an access token.');
  }
  const response = await config.fetch(`${config.apiBase}${options.path}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      'PayPal-Request-Id': options.requestId,
    },
    body: JSON.stringify(options.body),
    signal: signal(),
  });
  if (!response.ok) throw await toPayPalApiError(options.operation, response);
  return (await response.json()) as Record<string, unknown>;
}

/** Maps provider failures to safe API errors; internal details stay in the logs. */
function mapPayPalFailure(error: unknown, operation: string): never {
  if (error instanceof HttpError) throw error;
  if (error instanceof PayPalApiError) {
    // Capturing before the payer approved (they came back without paying).
    if (error.status === 422 && error.details.some((d) => d.issue === 'ORDER_NOT_APPROVED')) {
      throw new HttpError(
        409,
        'paypal_not_approved',
        'This payment has not been approved in PayPal yet. Finish paying in PayPal, or cancel.',
      );
    }
    if (error.status === 422) {
      throw new HttpError(400, 'paypal_rejected', `PayPal Sandbox rejected the ${operation}.`);
    }
    throw new HttpError(
      502,
      'paypal_unavailable',
      `PayPal Sandbox ${operation} failed. Please try again.`,
    );
  }
  logger.error(
    { errorName: error instanceof Error ? error.name : 'Error' },
    `PayPal ${operation} failed`,
  );
  throw new HttpError(
    502,
    'paypal_unavailable',
    `PayPal Sandbox ${operation} could not be completed. No balance was added.`,
  );
}

async function requireCard(uid: string, vehicleId: string) {
  await requireOwnedVehicle(uid, vehicleId);
  const card = await ChargingCard.findOne({ uid, vehicleId }).lean();
  if (!card) throw notFound('No charging card is registered for this vehicle.', 'card_not_found');
  return card;
}

export async function createRechargeOrder(
  config: PayPalConfig,
  uid: string,
  vehicleId: string,
  amountInr: number,
  returnTo: RechargeReturnTo = 'web',
) {
  const amountPaise = validateRechargeAmount(amountInr);
  const card = await requireCard(uid, vehicleId);
  if (card.currency !== 'INR') {
    throw badRequest('PayPal Sandbox demo conversion requires an INR charging card.');
  }
  const paypalAmountCents = convertInrToUsdCents(amountPaise, config.demoExchangeRateInrToUsd);

  let order: Record<string, unknown>;
  try {
    order = await paypalRequest(config, {
      operation: 'order creation',
      path: '/v2/checkout/orders',
      requestId: randomUUID(),
      body: {
        intent: 'CAPTURE',
        purchase_units: [
          {
            reference_id: vehicleId,
            description: 'EV Smart Companion charging-card recharge',
            amount: {
              currency_code: PAYPAL_SANDBOX_CURRENCY,
              value: formatCents(paypalAmountCents),
            },
          },
        ],
        application_context: {
          brand_name: 'EV Smart Companion',
          landing_page: 'LOGIN',
          user_action: 'PAY_NOW',
          return_url: returnTo === 'app' ? APP_RETURN_URL : WEB_RETURN_URL,
          cancel_url: returnTo === 'app' ? APP_CANCEL_URL : WEB_CANCEL_URL,
        },
      },
    });
  } catch (error) {
    mapPayPalFailure(error, 'order creation');
  }

  const orderId = typeof order.id === 'string' ? order.id : '';
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(orderId)) {
    mapPayPalFailure(new Error('PayPal Sandbox did not return an order ID.'), 'order creation');
  }
  const links = Array.isArray(order.links) ? (order.links as Record<string, unknown>[]) : [];
  const approvalUrl = links.find((link) => link.rel === 'approve')?.href;
  if (typeof approvalUrl !== 'string') {
    mapPayPalFailure(
      new Error('PayPal Sandbox did not return an approval link.'),
      'order creation',
    );
  }

  await PaypalOrder.create({
    _id: orderId,
    uid,
    vehicleId,
    cardId: card._id,
    amountPaise,
    currency: 'INR',
    paypalAmountCents,
    paypalCurrency: PAYPAL_SANDBOX_CURRENCY,
    conversionType: CONVERSION_TYPE,
    demoExchangeRate: config.demoExchangeRateInrToUsd,
    status: 'PENDING',
  });

  return {
    success: true,
    orderId,
    approvalUrl,
    status: typeof order.status === 'string' ? order.status : 'CREATED',
    amount: paiseToRupees(amountPaise),
    currency: 'INR',
    paypalAmount: paypalAmountCents / 100,
    paypalCurrency: PAYPAL_SANDBOX_CURRENCY,
    conversionType: CONVERSION_TYPE,
    demoExchangeRate: config.demoExchangeRateInrToUsd,
    currentBalance: paiseToRupees(card.balancePaise),
    paypalClientId: config.clientId,
    paymentProvider: 'PayPal Sandbox',
  };
}

type OrderRecord = {
  _id: string;
  amountPaise: number;
  currency: string;
  paypalAmountCents: number;
  paypalCurrency: string;
  conversionType: string;
  demoExchangeRate: number;
  transactionId?: mongoose.Types.ObjectId | null;
  balanceAfterPaise?: number | null;
};

function captureResult(order: OrderRecord, vehicleId: string, extra: Record<string, unknown>) {
  return {
    success: true,
    vehicleId,
    transactionId: order.transactionId?.toString() ?? null,
    balanceAfter: order.balanceAfterPaise == null ? null : paiseToRupees(order.balanceAfterPaise),
    amount: paiseToRupees(order.amountPaise),
    currency: order.currency,
    paypalAmount: order.paypalAmountCents / 100,
    paypalCurrency: order.paypalCurrency,
    conversionType: order.conversionType,
    demoExchangeRate: order.demoExchangeRate,
    paymentProvider: 'PayPal Sandbox',
    ...extra,
  };
}

export async function captureRechargeOrder(
  config: PayPalConfig,
  uid: string,
  vehicleId: string,
  orderId: string,
) {
  await requireOwnedVehicle(uid, vehicleId, { requireActive: false });
  const order = await PaypalOrder.findById(orderId).lean<
    OrderRecord & { uid: string; vehicleId: string; status: string }
  >();
  // Someone else's order is reported exactly like a missing one.
  if (!order || order.uid !== uid || order.vehicleId !== vehicleId) {
    throw notFound('This PayPal order is not registered for capture.', 'order_not_found');
  }
  if (order.status === 'COMPLETED') {
    return captureResult(order, vehicleId, { alreadyCaptured: true });
  }
  const card = await requireCard(uid, vehicleId);

  let capture: Record<string, unknown>;
  try {
    capture = await paypalRequest(config, {
      operation: 'capture',
      path: `/v2/checkout/orders/${encodeURIComponent(orderId)}/capture`,
      // Same ID on retries, so PayPal returns the original capture instead of charging again.
      requestId: createHash('sha256').update(`${orderId}:capture`).digest('hex').slice(0, 36),
      body: {},
    });
  } catch (error) {
    mapPayPalFailure(error, 'capture');
  }

  type Capture = {
    id?: unknown;
    status?: unknown;
    amount?: { value?: unknown; currency_code?: unknown };
  };
  const units = capture.purchase_units as { payments?: { captures?: Capture[] } }[] | undefined;
  const verified = units?.[0]?.payments?.captures?.[0];
  if (capture.status !== 'COMPLETED' || verified?.status !== 'COMPLETED') {
    throw conflict('PayPal did not confirm a completed capture.', 'paypal_not_completed');
  }
  const capturedCents = Math.round(Number.parseFloat(String(verified.amount?.value ?? '0')) * 100);
  const capturedCurrency = String(verified.amount?.currency_code ?? '').toUpperCase();
  const expectedCents = convertInrToUsdCents(order.amountPaise, order.demoExchangeRate);
  if (
    order.conversionType !== CONVERSION_TYPE ||
    order.demoExchangeRate !== config.demoExchangeRateInrToUsd ||
    order.paypalCurrency !== PAYPAL_SANDBOX_CURRENCY ||
    order.paypalAmountCents !== expectedCents ||
    capturedCents !== expectedCents ||
    capturedCurrency !== PAYPAL_SANDBOX_CURRENCY ||
    order.currency !== card.currency
  ) {
    throw conflict(
      'The PayPal capture amount does not match the recharge order.',
      'paypal_amount_mismatch',
    );
  }
  const captureId = typeof verified.id === 'string' ? verified.id : '';
  if (!captureId) throw conflict('PayPal did not return a capture ID.', 'paypal_not_completed');

  const credit = () =>
    mongoose.connection.transaction(async (session) => {
      const fresh = await PaypalOrder.findById(orderId)
        .session(session)
        .lean<OrderRecord & { status: string }>();
      if (!fresh)
        throw notFound('This PayPal order is not registered for capture.', 'order_not_found');
      if (fresh.status === 'COMPLETED') {
        return captureResult(fresh, vehicleId, { alreadyCaptured: true });
      }
      const freshCard = await ChargingCard.findOne({ uid, vehicleId }).session(session);
      if (!freshCard) {
        throw notFound('No charging card is registered for this vehicle.', 'card_not_found');
      }
      const balanceBeforePaise = freshCard.balancePaise;
      const balanceAfterPaise = balanceBeforePaise + fresh.amountPaise;
      const now = new Date();
      freshCard.balancePaise = balanceAfterPaise;
      freshCard.lastRechargePaise = fresh.amountPaise;
      freshCard.lastRechargeAt = now;
      await freshCard.save({ session });
      const [transaction] = await CardTransaction.create(
        [
          {
            cardId: freshCard._id,
            uid,
            vehicleId,
            type: 'credit',
            amountPaise: fresh.amountPaise,
            balanceBeforePaise,
            balanceAfterPaise,
            currency: fresh.currency,
            paypalAmountCents: capturedCents,
            paypalCurrency: capturedCurrency,
            conversionType: fresh.conversionType,
            demoExchangeRate: fresh.demoExchangeRate,
            paymentProvider: 'PayPal Sandbox',
            paymentMethod: 'paypal',
            paypalOrderId: orderId,
            paypalCaptureId: captureId,
            status: 'completed',
            description: 'PayPal recharge',
            timestamp: now,
          },
        ],
        { session },
      );
      await PaypalOrder.updateOne(
        { _id: orderId },
        {
          status: 'COMPLETED',
          captureId,
          transactionId: transaction!._id,
          balanceAfterPaise,
          completedAt: now,
        },
        { session },
      );
      return captureResult(
        { ...fresh, transactionId: transaction!._id, balanceAfterPaise },
        vehicleId,
        { balanceBefore: paiseToRupees(balanceBeforePaise) },
      );
    });

  try {
    return await credit();
  } catch (error) {
    // A concurrent capture credited first; the unique paypalOrderId index stopped a double credit.
    if (isDuplicateKeyError(error)) return credit();
    throw error;
  }
}
