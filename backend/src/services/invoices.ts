import PDFDocument from 'pdfkit';
import { Types } from 'mongoose';

import { CardTransaction } from '../models/cardTransaction.js';
import { paiseToRupees } from '../models/common.js';
import { Counter, Invoice } from '../models/invoice.js';
import { PaypalOrder } from '../models/paypalOrder.js';
import { User } from '../models/user.js';
import { conflict, isDuplicateKeyError, notFound } from './errors.js';
import { requireOwnedVehicle } from './vehicles.js';

export type InvoiceRecord = {
  _id: Types.ObjectId;
  invoiceNumber: string;
  uid: string;
  vehicleId: string;
  transactionId: Types.ObjectId;
  paypalOrderId: string;
  paypalCaptureId: string;
  amountPaise: number;
  currency: string;
  paypalAmountCents: number;
  paypalCurrency: string;
  paymentMethod: string;
  status: 'PAID';
  sandbox: boolean;
  transactionAt: Date;
  createdAt: Date;
};

type TransactionRecord = {
  _id: Types.ObjectId;
  uid: string;
  vehicleId: string;
  type: string;
  status: string;
  amountPaise: number;
  currency: string;
  timestamp: Date;
  paymentProvider?: string | null;
  paymentMethod?: string | null;
  paypalOrderId?: string | null;
  paypalCaptureId?: string | null;
  paypalAmountCents?: number | null;
  paypalCurrency?: string | null;
};

const invoiceNotFound = () =>
  notFound('No invoice exists for this transaction.', 'invoice_not_found');

/**
 * Returns the invoice for a verified PayPal recharge, creating it on first
 * use. Safe to call repeatedly or concurrently: one transaction never gets
 * two invoices, and nothing here touches the payment or the card balance.
 */
export async function ensureInvoice(
  uid: string,
  vehicleId: string,
  transactionId: string,
): Promise<InvoiceRecord> {
  await requireOwnedVehicle(uid, vehicleId, { requireActive: false });
  if (!Types.ObjectId.isValid(transactionId)) throw invoiceNotFound();
  const transaction = await CardTransaction.findById(transactionId).lean<TransactionRecord>();
  // Someone else's transaction is reported exactly like a missing one.
  if (!transaction || transaction.uid !== uid || transaction.vehicleId !== vehicleId) {
    throw invoiceNotFound();
  }
  const existing = await Invoice.findOne({ transactionId: transaction._id }).lean<InvoiceRecord>();
  if (existing) return existing;

  // Only a recharge whose capture the backend verified with PayPal qualifies.
  const order = transaction.paypalOrderId
    ? await PaypalOrder.findById(transaction.paypalOrderId).lean<{
        status: string;
        captureId?: string | null;
        transactionId?: Types.ObjectId | null;
      }>()
    : null;
  if (
    transaction.type !== 'credit' ||
    transaction.status !== 'completed' ||
    !transaction.paypalOrderId ||
    !transaction.paypalCaptureId ||
    transaction.paypalAmountCents == null ||
    !transaction.paypalCurrency ||
    order?.status !== 'COMPLETED' ||
    order.captureId !== transaction.paypalCaptureId ||
    !order.transactionId?.equals(transaction._id)
  ) {
    throw conflict(
      'Invoices are available only for verified PayPal recharges.',
      'invoice_unavailable',
    );
  }

  const year = transaction.timestamp.getUTCFullYear();
  const counter = await Counter.findOneAndUpdate(
    { _id: `invoice-${year}` },
    { $inc: { value: 1 } },
    { upsert: true, returnDocument: 'after' },
  ).lean<{ value: number }>();
  const sandbox = (transaction.paymentProvider ?? '').toLowerCase() !== 'paypal';
  const invoiceNumber = `EVSC-${sandbox ? 'TEST-' : ''}${year}-${String(counter!.value).padStart(6, '0')}`;
  try {
    const created = await Invoice.create({
      invoiceNumber,
      uid,
      vehicleId,
      transactionId: transaction._id,
      paypalOrderId: transaction.paypalOrderId,
      paypalCaptureId: transaction.paypalCaptureId,
      amountPaise: transaction.amountPaise,
      currency: transaction.currency,
      paypalAmountCents: transaction.paypalAmountCents,
      paypalCurrency: transaction.paypalCurrency,
      paymentMethod: transaction.paymentMethod ?? 'paypal',
      status: 'PAID',
      sandbox,
      transactionAt: transaction.timestamp,
    });
    return created.toObject() as InvoiceRecord;
  } catch (error) {
    // A concurrent request created it first (its number is then unused).
    if (isDuplicateKeyError(error)) {
      const winner = await Invoice.findOne({
        transactionId: transaction._id,
      }).lean<InvoiceRecord>();
      if (winner) return winner;
    }
    throw error;
  }
}

export function invoiceJson(invoice: InvoiceRecord) {
  return {
    id: invoice._id.toString(),
    invoiceNumber: invoice.invoiceNumber,
    transactionId: invoice.transactionId.toString(),
    vehicleId: invoice.vehicleId,
    paypalCaptureId: invoice.paypalCaptureId,
    amount: paiseToRupees(invoice.amountPaise),
    currency: invoice.currency,
    paypalAmount: invoice.paypalAmountCents / 100,
    paypalCurrency: invoice.paypalCurrency,
    paymentMethod: invoice.paymentMethod,
    status: invoice.status,
    sandbox: invoice.sandbox,
    transactionAt: invoice.transactionAt.toISOString(),
    createdAt: invoice.createdAt.toISOString(),
  };
}

const NAVY = '#071326';
const MUTED = '#6F8EAF';
const ALERT = '#B42318';

function money(minorUnits: number, currency: string) {
  return `${currency} ${(minorUnits / 100).toFixed(2)}`;
}

/** Renders the receipt PDF from stored, verified data only. */
export async function renderInvoicePdf(invoice: InvoiceRecord): Promise<Buffer> {
  const customer = await User.findById(invoice.uid).lean<{ name?: string; email?: string }>();
  const doc = new PDFDocument({
    size: 'A4',
    margin: 56,
    info: {
      Title: `EV Smart Companion payment receipt ${invoice.invoiceNumber}`,
      Author: 'EV Smart Companion',
    },
  });
  const chunks: Buffer[] = [];
  doc.on('data', (chunk: Buffer) => chunks.push(chunk));
  const finished = new Promise<Buffer>((resolve, reject) => {
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);
  });

  drawLogo(doc, 56, 50, 46);
  doc.fillColor(NAVY).font('Helvetica-Bold').fontSize(20).text('EV Smart Companion', 114, 56);
  doc
    .fillColor(MUTED)
    .font('Helvetica')
    .fontSize(9)
    .text('DRIVE SMARTER. CHARGE SIMPLER.', 114, 82, { characterSpacing: 1.5 });

  doc.fillColor(NAVY).font('Helvetica-Bold').fontSize(16).text('PAYMENT RECEIPT', 56, 130);

  if (invoice.sandbox) {
    doc.roundedRect(56, 158, 483, 34, 6).fill('#FDECEC');
    doc
      .fillColor(ALERT)
      .font('Helvetica-Bold')
      .fontSize(14)
      .text('SANDBOX — TEST TRANSACTION', 56, 168, { width: 483, align: 'center' });
  }

  const rows: [string, string][] = [
    ['Receipt number', invoice.invoiceNumber],
    ['Customer name', customer?.name?.trim() || 'Not available'],
    ['Customer email', customer?.email?.trim() || 'Not available'],
    ['Vehicle', invoice.vehicleId],
    ['Description', 'EV Smart Companion charging-card recharge'],
    ['Amount credited', money(invoice.amountPaise, invoice.currency)],
    ['Amount charged by PayPal', money(invoice.paypalAmountCents, invoice.paypalCurrency)],
    ['Payment method', invoice.sandbox ? 'PayPal (Sandbox)' : 'PayPal'],
    ['PayPal transaction (capture) ID', invoice.paypalCaptureId],
    ['PayPal order ID', invoice.paypalOrderId],
    ['Payment date and time (UTC)', formatUtc(invoice.transactionAt)],
    ['Payment status', 'Paid (verified with PayPal)'],
    ['Receipt issued (UTC)', formatUtc(invoice.createdAt)],
  ];
  let y = 214;
  for (const [label, value] of rows) {
    doc.fillColor(MUTED).font('Helvetica').fontSize(10).text(label, 56, y, { width: 190 });
    doc.fillColor(NAVY).font('Helvetica-Bold').fontSize(10).text(value, 250, y, { width: 289 });
    y = Math.max(doc.y, y + 14) + 10;
    doc
      .moveTo(56, y - 5)
      .lineTo(539, y - 5)
      .lineWidth(0.5)
      .strokeColor('#E0E7EF')
      .stroke();
  }

  const notice = invoice.sandbox
    ? 'This receipt records a PayPal Sandbox test payment. No real money was transferred, ' +
      'and it is not proof of a real payment. '
    : '';
  doc
    .fillColor(MUTED)
    .font('Helvetica')
    .fontSize(8.5)
    .text(
      `${notice}This is a payment receipt for a charging-card recharge, not a tax invoice: ` +
        'it carries no seller tax registration or tax breakdown.',
      56,
      y + 16,
      { width: 483 },
    );
  doc.end();
  return finished;
}

function formatUtc(date: Date) {
  return date
    .toISOString()
    .replace('T', ' ')
    .replace(/\.\d{3}Z$/, '');
}

/** The app logo's dark circle and bolt, from lib/widgets/ev_logo.dart. */
function drawLogo(doc: PDFKit.PDFDocument, x: number, y: number, size: number) {
  const scale = size / 464;
  doc.save();
  doc.translate(x, y).scale(scale).translate(-93, 0);
  doc.circle(325, 232, 232).fill('#0B1524');
  doc.lineWidth(5).lineJoin('round').lineCap('round').strokeColor('#5B7FA8');
  doc
    .path(
      'M180 370 C120 320 108 260 108 200 C108 110 200 62 325 62 C450 62 542 110 542 200 ' +
        'C542 260 530 320 468 370 L468 402 Q468 420 450 420 L430 420 Q412 420 412 402 ' +
        'L412 388 L238 388 L238 402 Q238 420 220 420 L200 420 Q180 420 180 402 Z',
    )
    .stroke();
  doc.circle(200, 332, 22).stroke();
  doc.circle(448, 332, 22).stroke();
  const gradient = doc.linearGradient(273, 118, 388, 348);
  gradient.stop(0, '#3A9AD9').stop(1, '#2DBE8E');
  doc
    .polygon([358, 118], [273, 247], [322, 247], [289, 348], [388, 217], [340, 217])
    .fill(gradient);
  doc.restore();
}
