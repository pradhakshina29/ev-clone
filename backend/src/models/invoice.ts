import { model, Schema, Types, type InferSchemaType } from 'mongoose';

import { nonNegativeInteger } from './common.js';

// One payment receipt per verified PayPal recharge (credit transaction).
// Holds only verified payment data: no PayPal credentials, no card numbers.
// The PDF is generated on each authenticated download, so no file or URL
// is stored.
const invoiceSchema = new Schema(
  {
    invoiceNumber: { type: String, required: true, maxlength: 40 },
    uid: { type: String, required: true },
    vehicleId: { type: String, required: true, maxlength: 64 },
    transactionId: { type: Types.ObjectId, required: true, ref: 'CardTransaction' },
    paypalOrderId: { type: String, required: true, maxlength: 128 },
    paypalCaptureId: { type: String, required: true, maxlength: 128 },
    amountPaise: { type: Number, required: true, validate: nonNegativeInteger },
    currency: { type: String, required: true, match: /^[A-Z]{3}$/ },
    paypalAmountCents: { type: Number, required: true, validate: nonNegativeInteger },
    paypalCurrency: { type: String, required: true, match: /^[A-Z]{3}$/ },
    paymentMethod: { type: String, required: true, maxlength: 40 },
    status: { type: String, required: true, enum: ['PAID'] },
    sandbox: { type: Boolean, required: true },
    transactionAt: { type: Date, required: true },
  },
  { timestamps: true, versionKey: false },
);

// Exactly one invoice per transaction, even under concurrent requests.
invoiceSchema.index({ transactionId: 1 }, { unique: true });
invoiceSchema.index({ invoiceNumber: 1 }, { unique: true });

export type InvoiceDocument = InferSchemaType<typeof invoiceSchema>;
export const Invoice = model('Invoice', invoiceSchema, 'invoices');

// Atomic sequence for invoice numbers.
const counterSchema = new Schema(
  {
    _id: { type: String, required: true },
    value: { type: Number, required: true, default: 0 },
  },
  { versionKey: false },
);

export const Counter = model('Counter', counterSchema, 'counters');
