# EV Smart Companion backend

Node.js + TypeScript + Express API backed by MongoDB Atlas. The Flutter app
signs up and logs in here (`/v1/auth`: email + bcrypt-hashed password, a
15-minute JWT access token and a rotating 7-day refresh token stored only as a
hash) and sends the access token as `Authorization: Bearer <token>`; this
server verifies it and serves profile,
vehicle, maintenance, controls-preference, charging-card, PayPal and learning
assistant data.

Live vehicle measurements are **not** stored or served here. They come only
from the BLE simulator.

## Setup

1. Install Node.js 22 or newer.
2. `cd backend` then `npm install`.
3. Copy `.env.example` to `.env` and fill in every `REPLACE_ME`. Never commit `.env`.
4. `npm run check-env` prints `present` or `missing` for each variable (never the values).
   `GEMINI_FALLBACK_MODEL` is optional (default `gemini-flash-lite-latest`): the
   learning assistant asks it once when `GEMINI_MODEL` is overloaded (503),
   rate limited (429) or times out. Both must be Gemini models available to
   your key.

## Commands

| Command                   | What it does                                                               |
| ------------------------- | -------------------------------------------------------------------------- |
| `npm run dev`             | Start the API on http://localhost:8081 with reload                         |
| `npm run build`           | Compile TypeScript to `dist/`                                              |
| `npm start`               | Run the compiled server (used on Render)                                   |
| `npm test`                | Run tests against an in-memory MongoDB replica set                         |
| `npm run lint`            | ESLint                                                                     |
| `npm run typecheck`       | TypeScript type check, including tests                                     |
| `npm run format`          | Prettier                                                                   |
| `npm run check-env`       | Check that every environment variable is set                               |
| `npm run seed`            | Insert or update the demo vehicles (safe to re-run)                        |
| `npm run reset-demo-data` | Delete all accounts and their data, release every vehicle (demo data only) |

`GET /health` returns `{"status":"ok"}` without auth or database access. Every
route under `/v1` except `/v1/auth/signup`, `/login`, `/refresh` and `/logout`
requires a valid access token. Changing `JWT_SECRET` signs everyone out.

Map proxy (`/v1/geo/route`, `/v1/geo/overpass`): OSRM and the public Overpass
servers chain to the ISRG Root X2 certificate, which Android only trusts from
Android 14, so phones on older Android cannot call them directly. The app
fetches routes and charging stations through these endpoints (30 requests per
minute per user) and falls back to the public servers only if the backend is
unreachable.

Payment receipts: see `docs/paypal-checkout.md`.

## Troubleshooting

- `bad auth : authentication failed`: the username or password in `MONGODB_URI`
  does not match a user in Atlas → Security → Database Access.
- `MongoServerSelectionError` / timeout: add your IP in Atlas → Network Access,
  or URL-encode special characters in the password (`@`→`%40`, `#`→`%23`,
  `/`→`%2F`, `:`→`%3A`).
