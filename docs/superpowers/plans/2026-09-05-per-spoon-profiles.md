# Plan — Per-spoon (per-person) data, keyed by stable hardware ID

Date: 2026-09-05 · Branch: `feat/per-spoon-profiles`
Decisions (user): spoon = person (auto) · one login, many spoons · key by **stable hardware ID (productId)** · local + Neon together · both+reconcile (already: firmware adaptive + app detector live).

## Problem
All analytics are keyed by `user_id` only, so both paired spoons show the SAME
numbers (34 bites / 17s / Lunch 34), and stale values show even when a spoon is
disconnected. Firmware bite counter is per-spoon at the source, but the app
aggregates globally.

## Stable key
`spoonKeyFor(deviceId)` = the saved device's `productId` (hardware Device ID),
falling back to `deviceId` when no productId is known. Survives BLE address
rotation (RPA) and reflash. Old rows backfill `spoon_key = device_id`.

## Status: IMPLEMENTED (2026-09-05)
T1–T7 done. App analyze clean (only pre-existing ai_lab infos). Backend syntax
OK. Neon migration 020 applied (spoon_key column live). APK built.

## Tasks

### T1 — App: stable-key resolver + per-spoon today aggregates
- `UnifiedDataService.spoonKeyFor(deviceId)` via `BleService().previousDevices`.
- Replace scalar `_todayBites/_todayEatingMin/_todayAvgTemp/_today*Bites`
  with per-spoon maps keyed by spoon_key (`Map<String, TodaySpoonStats>`).
- `_loadTodaySnapshot()` loads per-spoon rows.
- Per-device getters resolve deviceId→spoonKey: `totalBitesFor`, breakdown
  (`breakfast/lunch/dinner/snackTotalBitesFor`), avg speed.
- Keep legacy global getters as "active/primary spoon" for back-compat.
- Verify: `flutter analyze`.

### T2 — Recording tags spoon_key
- On meal create, set `meals.spoon_key = spoonKeyFor(sessionDeviceId)`.
- Background bite reconciliation attributes to the connected spoon's key only.
- Verify: `flutter analyze`.

### T3 — Local DB migration v15
- `ALTER TABLE meals ADD COLUMN spoon_key TEXT` (additive, nullable).
- Backfill `spoon_key = device_id` for existing meals.
- `daily_summaries`: rebuild per `(user_id, spoon_key, date)` (new table, copy).
- `getTodaySnapshotForSpoon(userId, spoonKey)` + per-spoon aggregate rebuild.
- Verify: schema creates clean on fresh install + upgrades from v14.

### T4 — Home UI
- Eating Analysis card uses per-device breakdown getters (not global).
- Each per-device section already passes its deviceId → now shows that spoon.
- A disconnected spoon shows its OWN last data, not another spoon's.
- Verify: `flutter analyze`.

### T5 — Background single-spoon attribution
- Only the one connected spoon's bites are counted in the bg isolate; persisted
  under its spoon_key so switching spoons attributes correctly.
- Verify: `flutter analyze`.

### T6 — Backend (Neon) mirror
- Migration: add `spoon_key` to meals/bites/daily aggregates; backfill.
- Controllers/models scope by `user_id + spoon_key`.
- Sync carries spoon_key.
- Verify: backend syntax check + tests.

### T7 — Build + verify
- `flutter analyze` clean.
- Build APK to Desktop with ngrok URL.
- Run Neon migration via backend migrate script.
