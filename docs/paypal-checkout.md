# PayPal checkout by platform

PayPal order creation and capture are authenticated calls to the backend
(`backend/`): `POST /v1/vehicles/{vehicleId}/charging-card/paypal-orders`
with `{ "amountInr": 100 }`, then
`POST /v1/vehicles/{vehicleId}/charging-card/paypal-orders/{orderId}/capture`.
The backend validates the INR recharge (at most ₹10,000, two decimals),
calculates the fixed DEMO-only INR-to-USD Sandbox amount
(`DEMO_EXCHANGE_RATE_INR_TO_USD`), verifies PayPal's completed capture, and
credits the INR amount once in a MongoDB transaction; capturing the same order
again returns the original result without a second credit. The app receives
only the order ID, approval URL and the public PayPal client ID; the PayPal
secret and OAuth token stay in `backend/.env`.

## Payment receipts (PDF)

After a verified capture the backend creates one receipt record per credit
transaction (`invoices` collection, unique per transaction) with a sequential
number such as `EVSC-TEST-2026-000001`. Creating it never touches the payment:
if it fails, the capture still succeeds and the receipt is created on the
first download instead.

- `GET /v1/vehicles/{vehicleId}/charging-card/transactions/{transactionId}/invoice`
  returns the receipt details (creating it if needed).
- `GET …/invoice.pdf` returns the PDF (`Cache-Control: private, no-store`).

Both need the owner's access token; another user's transaction answers 404.
Only PayPal credits whose order is `COMPLETED` with a matching capture ID get
a receipt (others answer 409 `invoice_unavailable`). The PDF is generated on
each download from stored, verified data; no file or public URL exists.
Sandbox receipts are marked **SANDBOX — TEST TRANSACTION** and state that no
real money moved.

These are payment receipts, not tax invoices. A legally compliant tax invoice
(for example a GST invoice in India) would also need the seller's legal name,
address and tax registration number (GSTIN), place of supply, HSN/SAC code,
and a tax breakdown; none of these exist in the project, so none are invented.

In the app, **Download invoice** appears on the recharge-success screen and on
each verified PayPal recharge in the transaction history. It hands the PDF to
the share sheet on Android/iOS (save to Files, Drive or open in a PDF viewer)
and downloads it on the web.

## Web

Flutter Web uses PayPal's official JavaScript SDK v6 Sandbox core and one-time
payment session. The PayPal checkout opens in the SDK-supported popup, leaving
the recharge screen in place. Its approval callback calls the backend capture
endpoint; only a successful backend capture marks the recharge successful. The app does not embed PayPal login in a WebView.

## Android and iOS

Native Android/iOS currently retain the clearly labeled external PayPal
approval URL fallback. Native PayPal SDK checkout return handling is pending
until the project has a real HTTPS domain configured and verified for Android
App Links and iOS Universal Links. No placeholder domain or deep-link
association is configured.

## Official SDK references

- [PayPal JavaScript SDK v6 reference](https://developer.paypal.com/sdk/js/reference/)
- [PayPal Android Mobile SDK overview](https://developer.paypal.com/sdk/android/overview)
- [PayPal iOS Mobile SDK overview](https://developer.paypal.com/sdk/ios/overview)
