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

The app creates the order with `"returnTo": "app"`. The backend then sets
PayPal's `return_url` / `cancel_url` to the app deep links
`evsmartcompanion://paypal-return` and `evsmartcompanion://paypal-cancel`
(PayPal Sandbox accepts custom-scheme return URLs). Web orders keep their
previous URLs because the SDK popup ignores them.

1. **Continue to PayPal** opens the approval page in a Chrome Custom Tab
   (Android) or `ASWebAuthenticationSession` (iOS) through
   `flutter_web_auth_2`. The deep links reach the app through the same
   exported `CallbackActivity` as the Spotify sign-in (Android manifest:
   hosts `spotify-callback`, `paypal-return`, `paypal-cancel`).
2. The dialog shows **Waiting for PayPal…** with **Confirm payment**,
   **Open PayPal again** and **Cancel** always available.
3. How the payer comes back:
   - **Return link** (approved): the app calls the backend capture right away.
   - **Cancel link**: "Payment cancelled in PayPal. No money was taken."
   - **Tab closed** without a link: "PayPal was closed. If you finished
     paying, tap Confirm payment…".
4. **Confirm payment** calls the backend capture. If the payer has not
   approved yet, the backend answers `409 paypal_not_approved`; the order stays
   pending and the dialog explains what to do. Nothing is credited.
5. Only a successful backend capture shows **Recharge successful**. The
   capture is idempotent (one credit per order). The card balance and the
   transaction list refresh at once, and **Download invoice** hands the PDF
   to the share sheet.

The dialog cannot be dismissed by tapping outside it, scrolls on small screens
and above the keyboard, and blocks Back only while the capture is being
confirmed.

A native PayPal SDK checkout with verified App Links / Universal Links would
need a real HTTPS domain; none is configured.

## Official SDK references

- [PayPal JavaScript SDK v6 reference](https://developer.paypal.com/sdk/js/reference/)
- [PayPal Android Mobile SDK overview](https://developer.paypal.com/sdk/android/overview)
- [PayPal iOS Mobile SDK overview](https://developer.paypal.com/sdk/ios/overview)
