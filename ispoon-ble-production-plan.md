# iSpoon — Production BLE Connection Architecture
## Multi-Device Auto-Connect, Foreground + Background, Complete Plan
### Handoff document for implementation (Flutter app; firmware facts included)

> **Scope:** Everything the app needs to auto-connect to one or many spoons in
> foreground AND background, modeled on how top wearable companies (Xiaomi/Mi
> Band, Fitbit/Google, Garmin, Oura, Whoop, Polar) run their BLE stacks. The
> firmware side is already implemented and verified (continuous fast/slow
> advertising, clean disconnects, fixed 129-byte notifications @ 10 Hz, unique
> MAC per spoon, no bonding). Firmware facts appear where the app depends on
> them; optional firmware upgrades are listed at the end.

---

# 1. How the industry actually does it (benchmark)

Patterns common to every major wearable vendor, distilled:

| Pattern | Who uses it | What it means for iSpoon |
|---|---|---|
| **Registered-devices model** | All (Mi Fitness, Fitbit, Garmin Connect) | Persisted registry of paired devices added via an explicit in-app pairing flow; never a single "last connected" slot |
| **App-owned pairing, not OS settings** | All | User adds the spoon inside the app; the app owns identity, reconnect policy, and UI |
| **"Connect to any registered device that appears"** | All | If nothing is connected, scan by service UUID and connect to any registry match |
| **OS-anchored background reconnect** | All | Android: `autoConnect` + PendingIntent scan (+ CompanionDeviceManager on modern apps); iOS: pending `connect()` + State Restoration |
| **Foreground service while streaming (Android)** | Fitbit, Garmin, Whoop, Polar | A `connectedDevice` foreground service keeps the process alive during live data streaming |
| **Single connection-manager singleton** | All | Exactly one owner of every scan/connect/disconnect call; UI observes state, never drives radios directly |
| **Aggressive reconnect with backoff** | Whoop, Oura (continuous-data products) | Immediate retry on disconnect, exponential backoff on repeated failure, reset on success |
| **Local buffering + sync** | All | Data written to local DB the moment it arrives; upload/aggregation is a separate concern |
| **BLE bonding** | Most consumer bands | Encrypted link + resolvable addresses. iSpoon firmware currently has NO bonding — see §12; the plan below works without it |

Key insight from all of these: **the phone is the reconnect brain; the
peripheral just advertises forever.** The iSpoon firmware already does its
half perfectly. Everything below is the phone half.

---

# 2. Target behavior (definition of the goal)

1. User pairs each spoon once via an in-app "Add device" screen.
2. From then on, whenever any registered spoon is powered on and in range,
   the app connects to it automatically — app in foreground, background, or
   (Android) even killed; phone rebooted; Bluetooth toggled — within seconds
   in foreground, and within the OS-permitted window in background.
3. Turning one spoon off causes automatic failover to any other registered
   spoon that is on (≤ 5 s in foreground).
4. Optionally, the app can hold **multiple spoons connected simultaneously**
   (multi-user study mode) — see §6.
5. Incoming 129-byte packets are parsed and persisted locally regardless of
   whether the UI is visible.

---

# 3. App architecture (layers)

```
┌────────────────────────────────────────────────────────┐
│ UI layer (screens observe state streams; never touch    │
│ the BLE plugin directly)                                 │
├────────────────────────────────────────────────────────┤
│ ConnectionManager (SINGLETON, the only BLE owner)       │
│  • DeviceRegistry (persisted known spoons)              │
│  • Per-device ConnectionFSM (state machine, §5)         │
│  • ScanController (one shared scanner, UUID-filtered)   │
│  • ReconnectPolicy (backoff, §5.4)                      │
├────────────────────────────────────────────────────────┤
│ DataPipeline: packet parser → local DB (drift/sqlite)   │
│  → analytics (bites, tremor) → sync                     │
├────────────────────────────────────────────────────────┤
│ Platform layer                                          │
│  Android: Foreground Service (connectedDevice type),    │
│    PendingIntent background scan, CompanionDeviceManager│
│  iOS: CoreBluetooth State Restoration, background mode  │
└────────────────────────────────────────────────────────┘
```

Rules:
- **One singleton** owns every `startScan / connect / disconnect` call.
  Duplicate owners are the root cause of "sometimes works" flakiness.
- One shared scan session, filtered by service UUID
  `f00d0001-1234-5678-9abc-def012345678` (full 128-bit, lowercase, dashed).
- UI subscribes to `Stream<Map<deviceId, ConnState>>` and
  `Stream<SpoonPacket>`; it never calls the plugin.

---

# 4. Device registry & identity (multi-spoon foundation)

```dart
class KnownSpoon {
  final String id;        // remoteId: MAC on Android, CB UUID on iOS
  String label;           // default "ISPOON F6:86" (last 2 MAC bytes); user-renamable
  bool autoConnect;       // per-device toggle (default true)
  DateTime? lastConnected;
  int? lastBattery;
}
```

- Persisted (hive/shared_preferences/sqlite). Add via pairing screen only;
  **upsert + update `lastConnected` on EVERY successful connection** (this
  single rule fixes the "second spoon never auto-connects" bug class).
- Remove via UI ("Forget device").
- **iOS identity caveat:** iOS gives a phone-local UUID, not a MAC, and it can
  change after backup restore. Treat stored IDs as an optimization; the
  service-UUID scan is always the source of truth. If a stored iOS ID stops
  resolving, prune it and re-add on next scan match (match by name + a
  future firmware-provided serial — see §12.3).

---

# 5. Connection state machine (per device / per slot)

## 5.1 States & transitions

```
                    ┌────────────────────────────────────────────┐
                    ▼                                            │
 [IDLE] ─enable─▶ [SCANNING] ─registry match─▶ [CONNECTING] ─ok─▶ [SETUP] ─ok─▶ [STREAMING]
                    ▲    ▲                        │fail/10s        │fail            │
                    │    │                        ▼                ▼                │ disconnect /
                    │    └──backoff elapsed── [BACKOFF] ◀──────────┘                │ adapter off /
                    │                                                              ▼ spoon off
                    └──────────────────────────────────────────────────── [DISCONNECTED]
                                                                                │
                                                                                └─immediately─▶ SCANNING
```

- **SCANNING:** shared UUID-filtered scan; collect results ~1.5 s (debounce)
  before picking a target (RSSI policy, §6.1).
- **CONNECTING:** direct connect, **10 s timeout**; on timeout you MUST cancel
  the pending operation (`device.disconnect()`) before anything else —
  Android leaves zombie pending connects otherwise (classic GATT 133 factory).
- **SETUP (critical, often skipped):** discoverServices → find
  `f00d0002-...` → Android `requestMtu(247)` (belt-and-braces; firmware also
  initiates) → enable notifications (CCC write) → **verify first packet
  arrives within 3 s**. Any step failing ⇒ disconnect ⇒ BACKOFF. A connection
  without streaming data is a failure, not a success.
- **STREAMING:** watchdog — if no packet for 5 s while "connected", treat as a
  zombie link: disconnect ⇒ SCANNING. (Supervision timeout is 4 s
  firmware-side, so a live link never legitimately goes silent longer.)
- **DISCONNECTED ⇒ SCANNING immediately, every time.** This is the failover
  fix: spoon A off ⇒ scan finds spoon B ⇒ connect.

## 5.2 Triggers that (re)enter SCANNING
App start · any disconnect event · connect timeout/failure · setup failure ·
streaming watchdog · Bluetooth adapter ON event · permissions granted event ·
app resumed from background (defensive re-kick).

## 5.3 Triggers that stop all radio work ⇒ IDLE
Bluetooth adapter OFF · permissions revoked · user disables auto-connect ·
"Forget" of the only registered device. Every one of these must also cancel
pending connects and stop scans (no leaks).

## 5.4 Reconnect backoff policy
Attempt 1 immediately; then 2 s, 5 s, 15 s, 60 s cap; **reset to immediate on
any success or on any fresh advertisement from the target**. Prevents
reconnect storms against a spoon that is present but faulty, while staying
instant in the normal case.

## 5.5 Serialization rule (Android)
One GATT operation at a time per device (connect, discover, MTU, CCC write).
Queue them. Concurrent GATT ops are the #2 cause of status-133 errors after
zombie pending connects.

---

# 6. Multi-spoon logic

## 6.1 Mode A — Single active spoon (consumer default)
- One FSM slot. When SCANNING and multiple registered spoons advertise:
  debounce 1.5 s, pick **strongest RSSI** (recommended for your testing
  workflow) or first-seen (simpler). Settings screen offers a manual picker
  (scan list with labels) to force a specific unit during experiments.
- Failover = the FSM loop itself: A disconnects ⇒ SCANNING ⇒ B found ⇒
  connect. No special code.

## 6.2 Mode B — Multiple spoons connected simultaneously (study mode)
BLE centrals (phones) support many concurrent peripheral links; each spoon is
its own single-link peripheral, so nothing firmware-side blocks this.

- Instantiate **one FSM per registered spoon** with `autoConnect=true`; all
  share the single ScanController (scan results are demultiplexed by
  remoteId to the matching FSM).
- Practical ceiling: **4–6 concurrent links** on typical Android hardware,
  ~10 theoretical; iOS similar. Cap in app config (start with 4).
- Throughput check: 129 B × 10 Hz ≈ 1.3 kB/s per spoon — 4 spoons ≈ 5 kB/s,
  trivial for BLE with the firmware's 30–50 ms intervals + DLE + 2M PHY.
- Data pipeline must tag every packet with `deviceId` (DB schema §9).
- UI: per-device connection chips (battery, RSSI, streaming indicator).

Ship Mode A first; Mode B is an additive layer over the same FSM.

---

# 7. Android — foreground + background (in depth)

## 7.1 Permissions matrix

| Android | Required | Notes |
|---|---|---|
| 12+ (API 31+) | `BLUETOOTH_SCAN` (with `neverForLocation` flag if no location inference), `BLUETOOTH_CONNECT` — runtime | Missing runtime grant ⇒ empty scans, no error |
| ≤ 11 | `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION` runtime **+ system Location toggle ON** | Location OFF ⇒ silent empty scans — the most common Android BLE failure |
| 14+ | Foreground service must declare `android:foregroundServiceType="connectedDevice"` | Crash on startForeground otherwise |

App must show an **actionable error state** (buttons to grant/enable) instead
of an empty device list when any of these are missing.

## 7.2 Foreground operation
Plain FSM of §5 with an active `startScan` in SCANNING. Nothing special.

## 7.3 Background operation — three cooperating mechanisms

**(1) Foreground Service while streaming (primary).**
When ≥ 1 spoon is STREAMING, run a foreground service (persistent
notification: "iSpoon connected — 132 bites today"). This keeps the process,
the GATT connections, and the parser alive through screen-off and Doze. Stop
it when nothing is connected for N minutes (configurable) to save battery.
This is what Fitbit/Garmin/Whoop notifications in your tray are.

**(2) `autoConnect: true` pending connects (OS-anchored reconnect).**
For every registered spoon not currently connected, hold
`connectGatt(autoConnect=true)`. The Bluetooth stack (not your process's
timers) completes the connection whenever that MAC advertises — it survives
Doze and works with the screen off. Caveats: it is **address-specific**
(hence the registry, never a single slot), it is slow-scan based (connect
may take 10–60 s in deep idle — normal), and stale pending connects must be
cancelled before direct connects (§5.1).

**(3) PendingIntent scan (process-resurrection).**
Register `BluetoothLeScanner.startScan(filters=[serviceUUID], pendingIntent)`.
If the app process is killed, the OS delivers the scan match to a
BroadcastReceiver, which restarts the foreground service ⇒ FSM ⇒ connect.
Register on: app start, BOOT_COMPLETED, adapter-on. This is how band apps
reconnect after a phone reboot without the user opening the app.

**(4) CompanionDeviceManager (CDM) — strongly recommended (API 26+).**
Associate each spoon during pairing via CDM. Benefits used by modern band
apps: `startObservingDevicePresence()` wakes the app when the device
appears/vanishes; associated apps get **exemptions from battery/background
restrictions**; on Android 12+ you may use `REQUEST_COMPANION_...` flows and
can even avoid location-tied scan permission paths. CDM association +
foreground service + autoConnect is the current "top company" Android recipe.

## 7.4 OEM battery killers (real-world #1 background failure)
Xiaomi/MIUI, Huawei, Oppo/OnePlus, Vivo, Samsung aggressive modes kill even
foreground-service apps. Mitigations (all the big vendors do these):
- Request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` exemption in onboarding.
- CDM association (§7.3.4) — grants OEM-respected exemptions on many skins.
- In-app help page with per-OEM instructions (dontkillmyapp.com content).
- Detect "we were killed" (service restart without state) and telemeter it.

## 7.5 Android edge cases checklist
- **Adapter OFF ⇒ ON:** listen to adapter state; on ON, re-register
  PendingIntent scan, re-arm autoConnects, kick FSMs to SCANNING.
- **Phone reboot:** BOOT_COMPLETED receiver re-registers everything.
- **GATT error 133:** treat as generic failure ⇒ close GATT fully ⇒ BACKOFF.
  Do not retry instantly in a tight loop.
- **Scan throttling:** Android blocks apps that start/stop scans >5× / 30 s —
  the shared ScanController must be the only scanner and must not flap.
- **App update / process death mid-connection:** on service (re)start, treat
  all persisted "connected" states as stale; verify with fresh
  `getConnectedDevices()` and rebuild FSM state from reality.

---

# 8. iOS — foreground + background (in depth)

## 8.1 Capabilities & Info.plist
- Background Modes: `bluetooth-central`.
- `NSBluetoothAlwaysUsageDescription` string.
- CoreBluetooth **State Restoration**: instantiate the central with a fixed
  `CBCentralManagerOptionRestoreIdentifierKey`, implement
  `willRestoreState` — iOS relaunches the app in background when a pending
  connect completes or a subscribed characteristic notifies, even after the
  app was suspended/jetsammed.

## 8.2 The iOS pattern (different from Android — no PendingIntent, no FGS)
1. On start: `retrievePeripherals(withIdentifiers:)` for all registry IDs and
   call `connect()` on each not-connected one. **iOS connects never time
   out** — leave them pending forever; iOS completes them whenever the
   peripheral advertises, including in background. This pending-connect pool
   IS the background reconnect mechanism.
2. Additionally scan by service UUID while in foreground (fast discovery of
   brand-new spoons). Background scanning by UUID also works but is
   duty-cycled (slow) — the firmware's UUID-in-main-AD-packet requirement is
   already satisfied, which is what makes background discovery possible at all.
3. On notify in background you get ~10 s of runtime per event — enough to
   parse and write packets to disk. Keep the background path allocation-light.

## 8.3 iOS hard limits (design around, cannot fix)
- **Force-quit by user (swipe-kill) disables all BLE relaunch** until the
  user reopens the app. Every vendor has this limitation; document it in-app.
- Local name is stripped from background advertisements — filter by service
  UUID only (already the plan).
- No MAC access; identity caveats of §4 apply.
- Multiple simultaneous connections work fine (Mode B supported).

---

# 9. Data pipeline (background-safe)

1. Notification callback ⇒ verify `length == 129` ⇒ parse (all
   little-endian): `[0] battery u8 | [1..2] temp i16×0.01°C | [3..6] ts u32 ms
   | [7..8] bites u16 | [9..128] 10 × (ax,ay,az mg; gx,gy,gz 0.01°/s) i16`.
2. Sample i time = `ts + i×10 ms`. **Reboot detection:** ts decreasing ⇒ new
   session row. **Gap detection:** ts jumps in 100 ms multiples ⇒ dropped
   packets; log count, don't error.
3. Write raw packets (or decoded rows) to sqlite/drift **immediately** in the
   BLE callback path — background time is not guaranteed beyond that.
   Analytics (bite trends, tremor FFT) read from DB, never from the live
   stream, so they survive process restarts.
4. Every row tagged `deviceId` (Mode B ready) + session id.

---

# 10. Full edge-case & condition matrix

| # | Condition | Required behavior |
|---|---|---|
| 1 | Spoon off (clean 3 s-hold shutdown) | Disconnect event ⇒ SCANNING; failover to any other registered spoon |
| 2 | Spoon battery dies / out of range | Supervision timeout ⇒ same as #1 (arrives ≤ ~4 s late) |
| 3 | Zombie link (connected, no data 5 s) | Watchdog disconnect ⇒ SCANNING |
| 4 | Two registered spoons advertising | RSSI policy after 1.5 s debounce (Mode A) or connect both (Mode B) |
| 5 | Unregistered spoon advertising | Ignore for auto-connect; visible only in pairing screen |
| 6 | Registered spoon connected by ANOTHER phone | It stops advertising ⇒ invisible; app keeps scanning; surface "in use elsewhere?" hint after prolonged absence |
| 7 | BT off ⇒ on | IDLE ⇒ re-register background hooks ⇒ SCANNING |
| 8 | Airplane mode toggle | Same as #7 |
| 9 | Permission revoked at runtime | IDLE + actionable error UI |
| 10 | Location OFF (Android ≤ 11) | Detect + actionable error UI (silent-empty-scan trap) |
| 11 | Phone reboot | Android: BOOT receiver restores; iOS: pending connects restore on first app open (or restoration event) |
| 12 | App killed by OS | Android: PendingIntent scan resurrects; iOS: State Restoration |
| 13 | App force-quit by user | Android: PendingIntent still fires (most OEMs); iOS: dead until reopened — document |
| 14 | Doze / screen off long | FGS + autoConnect keep link; reconnects may slow to 10–60 s — acceptable |
| 15 | OEM battery killer | §7.4 mitigations; telemeter kills |
| 16 | Connect timeout | Cancel pending ⇒ BACKOFF ⇒ SCANNING |
| 17 | GATT 133 / plugin error | Full GATT close ⇒ BACKOFF |
| 18 | MTU exchange fails (<132) | Firmware drops packets; app watchdog (#3) catches ⇒ reconnect fresh |
| 19 | CCC write fails | SETUP failure ⇒ retry via BACKOFF |
| 20 | Packet length ≠ 129 | Drop + count (should never fire) |
| 21 | ts goes backwards | Spoon rebooted ⇒ new session |
| 22 | Rapid on/off flapping by user | Backoff + debounce absorb; FSM has no illegal-transition path |
| 23 | App upgrade mid-connection | Rebuild state from `getConnectedDevices()` on start |
| 24 | iOS stored ID stops resolving | Prune registry entry; re-match via scan |
| 25 | Registry empty | Pairing screen is the only active surface; no scans in background |

---

# 11. Rollout plan & acceptance tests

**Phase 1 — Foreground correctness:** singleton manager, registry, FSM,
RSSI policy, SETUP verification, watchdog.
**Phase 2 — Android background:** FGS (connectedDevice) + autoConnect pool +
adapter/boot receivers + PendingIntent scan.
**Phase 3 — Android hardening:** CDM association, battery-optimization
onboarding, OEM help page, telemetry.
**Phase 4 — iOS:** State Restoration, pending-connect pool, background parse
path.
**Phase 5 — Mode B multi-connect** (per-device FSMs, capped 4).

**Acceptance (all without app restart):**
A1 Swap test: A off, B on ⇒ connected & streaming ≤ 5 s foreground; 10/10.
A2 Failover both directions, 5× each.
A3 Screen off 30 min ⇒ still streaming (Android FGS).
A4 App killed (adb `am kill`) ⇒ spoon power-cycle ⇒ auto-reconnect ≤ 60 s.
A5 Phone reboot ⇒ spoon on ⇒ reconnect without opening app (Android).
A6 iOS backgrounded 1 h ⇒ spoon power-cycle ⇒ data resumes (restoration).
A7 BT toggle off/on ⇒ recovery ≤ 10 s.
A8 Both spoons on ⇒ RSSI pick correct; manual picker overrides.
A9 (Mode B) 2 spoons streaming simultaneously 10 min, 0 length errors,
gap rate < 1%.
A10 Permission/location degraded ⇒ actionable UI, zero silent failures.

---

# 12. Firmware: already done vs optional upgrades

## 12.1 Already implemented (app can rely on)
Continuous advertising (fast 30 s ⇒ slow forever, UUID in main AD packet —
this is precisely what enables iOS/Android background discovery); clean
confirmed disconnect on power-off; auto conn-params/2M PHY/DLE/MTU;
always-129-byte notifications @ 10 Hz; drop-oldest under stall; unique
static-random MAC per unit.

## 12.2 Optional next: BLE bonding (industry norm)
`CONFIG_BT_SMP=y` + Just Works pairing + `CONFIG_BT_SETTINGS` persistence.
Gains: encrypted link, controller-level whitelist (only bonded phones can
connect), resolvable-address friendliness on iOS. Cost: pairing UX + bond
management (forget-device must clear both sides). Recommended before any
real-user deployment; not needed to make auto-connect work.

## 12.3 Optional: Device Information Service (DIS, 0x180A)
Expose model + serial (FICR-derived) + firmware version. Gives the app a
stable cross-platform identity (fixes the iOS re-identification corner case
#24) and enables per-unit firmware tracking. ~20 lines of firmware.

## 12.4 Optional: directed advertising to bonded peer
After bonding, brief directed advertising on power-on makes reconnects
near-instant. Nice-to-have only.

---

## One-paragraph brief for the implementing session

Build a singleton ConnectionManager that owns all BLE calls: a persisted
multi-device registry (upserted on every successful connection), one shared
service-UUID-filtered scanner, and a per-device state machine
(SCANNING→CONNECTING(10 s timeout + pending-cancel)→SETUP(discover, MTU 247,
enable notify, verify first packet ≤ 3 s)→STREAMING(5 s data watchdog)) that
re-enters SCANNING on every disconnect/failure with exponential backoff reset
on success. Foreground failover falls out of the loop. Background: on
Android, a `connectedDevice` foreground service while streaming + an
`autoConnect=true` pool for absent registered devices + PendingIntent UUID
scan and boot/adapter receivers for process resurrection + CompanionDevice
association and battery-optimization exemption; on iOS, State Restoration
with a never-timing-out pending `connect()` pool and UUID-filtered scanning,
accepting the force-quit limitation. RSSI-based selection (with manual
picker) when several registered spoons advertise; optional Mode B runs one
FSM per spoon for up to 4 simultaneous connections. Parse the fixed 129-byte
packet to sqlite in the callback path, tag by deviceId, detect reboots by
backward timestamps. Validate against acceptance tests A1–A10.
