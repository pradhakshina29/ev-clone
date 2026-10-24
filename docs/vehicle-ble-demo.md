# Vehicle BLE demo

The authenticated Vehicle connection screen and Controls page in the main EV
Smart Companion app use the shared BLE central. The user must click
**Connect Vehicle** on either screen to start a connection; opening the app or
Controls does not start BLE automatically. For the demonstration, run the main
app in desktop Chrome and run the separate `vehicle_simulator/` Android app as
the BLE peripheral on the Samsung phone. The simulator sends all demo state
over BLE; it does not write to the backend or database. The main app accepts state only when
its `vehicleId` matches the vehicle selected by the signed-in user.

Login tokens are kept in memory only, so every launch and every page reload
(F5) shows Login. Signing out disconnects Bluetooth and returns to Login.

Chrome Web Bluetooth requires a secure context (HTTPS, or localhost), an
enabled Bluetooth adapter, a supported desktop browser/operating system, and
user permission from Chrome's device chooser. The Controls connection panel
reports API support, secure-context status, adapter availability (when exposed
by the browser), and Bluetooth permissions-policy status. If the API is
missing, use current desktop Chrome or Edge and open the app directly rather
than in a restricted iframe.
On the web, click **Connect Vehicle** to open the browser chooser. On Android,
the same action begins BLE discovery. If the BLE link is lost after selection,
the app retries the selected device with bounded
backoff; after retries are exhausted, click **Reconnect** to retry. Use
**Disconnect** to intentionally stop the link.
The chooser and device permission are managed by Chrome, not the app.

## Run on Windows PowerShell

Start each command group in its own terminal, from the repository folder.
Keep the backend and the simulator running while using the web app.

**Terminal 1 — Backend API (needs `backend/.env`, see `backend/README.md`)**

```powershell
cd backend
npm run dev
```

Check it at http://localhost:8081/health (`{"status":"ok"}`).

**Terminal 2 — BLE peripheral on the Android phone**

```powershell
cd vehicle_simulator
flutter run -d <your-phone-id>
```

Run `flutter devices` in this terminal and use the ID shown for the connected
phone.

**Terminal 3 — Main app in Chrome**

```powershell
flutter run -d chrome --web-hostname localhost --web-port 5100 --dart-define=API_BASE_URL=http://localhost:8081
```

In the simulator, enter the selected vehicle ID (for example `EV001`) and start
advertising. In the web app, click **Connect Vehicle** on the Vehicle
connection screen or in **Vehicle controls**. Select `EV-Simulator-01` from
Chrome's chooser. A successful BLE state is shown only after a valid snapshot
for the selected vehicle arrives.

The simulator's **Vehicle ID** must exactly match the selected vehicle
document ID shown on the Controls page. It is not the registration number, VIN,
model, Bluetooth device name, or Bluetooth device ID. On mismatch, the BLE
client reports both document IDs and disconnects without retrying the same
incorrect identity; correct the simulator ID, stop/restart its advertising,
then retry from Controls.

## Run the demo

1. Serve the Flutter Web app from `localhost` during development or from an
   HTTPS origin for the demonstration. Build with `flutter build web` before
   deploying it.
2. Open the app in current desktop Google Chrome and sign in normally. Open Controls and copy
   the displayed vehicle document ID.
3. From `vehicle_simulator/`, run the simulator on the Samsung phone. Enter the
   same vehicle ID and start the simulator. Allow Android's nearby-device/
   Bluetooth advertising permissions and leave the simulator open.
4. In Chrome, click **Connect Vehicle** on the Vehicle connection screen or
   Controls. Select the `EV-Simulator-01` device in Chrome's chooser and grant
   access.
5. The dashboard reports a BLE connection only after it receives and validates
   a state snapshot for the selected vehicle ID. Use the simulator controls to
   change state and verify real-time updates; choose **Vehicle disconnected**
   and **Vehicle reconnected** to exercise loss and recovery.

The simulator controls cover battery percentage, speed, four doors and
charging state. Scenarios cover parked/driving states, a moving vehicle with an
open or unlocked door, low and critical battery, charging start/completion/
interruption, and intentional BLE disconnect/reconnect. Charging state
advances in the simulator and stops at the configured target. Its local event
log keeps the most recent 40 demo events.

## Application-wide vehicle data

The app uses one application-scoped `VehicleBleClient`. Controls, dashboard,
vehicle health, charging map, trip planner, maintenance, learning, profile,
and vehicle details consume the same validated BLE snapshot. The Chrome device chooser is opened by the user-triggered **Connect Vehicle**
action on the Vehicle connection screen or Controls; opening other pages never
starts a second BLE connection.

Live battery, range, speed, charging, and control-state values are shown only
when a snapshot for the currently selected vehicle ID is
available. Disconnecting clears the shared snapshot, so consumers immediately
show unavailable values. The protocol is event-driven and does not send a
heartbeat; the app does not invent a stale timeout, and considers the last
snapshot current while the BLE link remains connected.

The backend (MongoDB) is the source for vehicle/account metadata, service
history, charging cards and Controls preferences; charging stations come from
OpenStreetMap. Neither is a fallback source for live measurements, and the
backend does not store or serve telemetry.

Component health travels in the optional `state.health` section of each
snapshot: battery (state of health, temperature, capacity, charge cycles, age,
voltage), motor (health, temperature, RPM, efficiency, status), four tyres
(pressure, tread), brakes (front/rear pad life, fluid status), software
(version, update available) and odometer. The simulator derives these from its
own driving and charging state, and its **Vehicle health** panel and health
scenarios change them for demos. Snapshots without `health` (older simulators)
are still accepted, and the app then shows "Not reported". Diagnostics the
simulator does not send (tyre temperatures, infotainment/firmware versions,
security status, efficiency and regeneration history) stay unavailable rather
than being inferred. The battery timeline on Vehicle Health is built only from
snapshots received during the current session and is cleared on sign-out.

Vehicle alerts are raised app-wide from the shared snapshot. Warnings and
critical alerts open a dialog over the current screen that only its OK / I
understand button closes; several alerts are queued and shown one after
another. Info alerts (charging started/complete, software update, a door open
or unlocked while parked) show a SnackBar. Each alert is saved in the per-vehicle
alert history with the time it was shown and acknowledged.

Controls preferences are stored per user and vehicle by the backend
(`GET`/`PUT /v1/vehicles/{vehicleId}/controls-preferences`). The backend checks
that the signed-in user owns the active vehicle; when nothing is saved yet it
returns the default preferences. An access error is shown as an error with
retry; the app does not substitute local or simulated preferences.

Safety alerts identify the affected door and distinguish open doors from
unlocked doors while moving. Active alert conditions are saved with the
signed-in user's per-vehicle controls preferences so navigating away and back
does not repeat the same alert. Alert history is capped at 50 entries.
Passenger profiles are scoped to the selected vehicle and preserve role, seat,
cabin preferences, left/right mirror adjustments, and last-used time. The
current BLE protocol applies cabin temperature, fan, and seat-heating settings;
seat assignment and mirror values are saved as profile preferences and are
not sent as vehicle commands.

## GATT protocol

The service and characteristics are versioned in
`packages/vehicle_ble_protocol/lib/vehicle_ble_protocol.dart`:

| Attribute | UUID | Role |
| --- | --- | --- |
| Vehicle Control service | `8a7e1000-6d8a-4a31-b8d1-1f40cc5a0001` | Advertised primary service |
| State characteristic | `8a7e1001-6d8a-4a31-b8d1-1f40cc5a0001` | Peripheral notifies snapshots |
| Command characteristic | `8a7e1002-6d8a-4a31-b8d1-1f40cc5a0001` | Central writes commands |

Both directions use UTF-8 JSON messages carried in BLE frames. Every frame is
`0xE7, messageId, frameCount, frameIndex, payload...`; the initial frame payload
is at most 16 bytes for the default 20-byte ATT payload. Receivers validate the
frame sequence, cap assembled messages at 4080 bytes, then validate JSON,
version, state ranges, and the exact four-door set.

State notifications have version `1`, type `state`, a vehicle ID, monotonic
sequence number, timestamp, and vehicle state, optionally with a `health`
section (backward compatible, so the version is unchanged). A full snapshot
with health is about 1.2 KB, well under the 4080-byte message limit. Commands have version `1`, type
`command`, a request ID, action, and only the fields required for that action.
The simulator validates every received command and rejects unsafe door,
charging, and vehicle-power transitions. The main app repeats those safety
checks before writing commands.

This is a local demonstration protocol, not an authenticated production vehicle
control interface. Do not connect it to a real vehicle or use it for
safety-critical actions.
