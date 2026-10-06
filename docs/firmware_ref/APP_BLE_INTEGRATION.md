# iSpoon mobile BLE integration

Firmware pairing uses **LE Secure Connections Just Works** (encrypted bond,
**no display PIN / passkey**). The spoon does not show a six-digit code. The
phone OS may still show a system pairing confirmation without a numeric entry.

An already bonded phone reconnects with its stored bond. To test first-time
pairing, remove/forget the spoon from the phone and use the spoon's documented
owner-reset long hold to clear its stored bond.

## UUIDs and operations

- Product service: `f00d0001-1234-5678-9abc-def012345678`
- TX notification: `f00d0002-1234-5678-9abc-def012345678`
- RX command: `f00d0003-1234-5678-9abc-def012345678`
- Device ID (open read, **no encrypt**): `f00d0004-1234-5678-9abc-def012345678`
- Hardware revision: `f00d0005-1234-5678-9abc-def012345678`
- Owner status (open read, **no encrypt**): `f00d0006-1234-5678-9abc-def012345678`
- Event notify (low-rate, open CCC): `f00d0007-1234-5678-9abc-def012345678`
- Standard Battery Service (BAS `0x180F`): level without bonding
- MCUmgr SMP service: `8d53dc1d-1db7-4cd3-868b-8a527460aa84`
- MCUmgr SMP characteristic: `da2e7828-fbce-4e01-ae9e-261174997c48`

### Advertising (primary AD — 31 B budget)

Primary AD carries **FLAGS + 128-bit service UUID + short name `iSpoon`**.  
Scan response carries complete name **`iSpoon Pro`** plus manufacturer data:

- Company ID `0xFFFF` (little-endian)
- Type `0x01`
- 8-byte nRF hwinfo Device ID

The BLE address rotates after a settings-erase flash; the Device ID does not.
Apps must key saved spoons and cloud rows by that 16-hex Device ID, not by MAC.
Apps may use platform `withServices: [f00d0001-…]` for Android HW filter and iOS background scan.

### Connection parameters

| Profile | When | Interval | Latency | Timeout |
|---|---|---|---|---|
| Streaming | bulk TX CCC on | 30–50 ms | 0 | 20 s |
| Idle | connected, bulk CCC off | 200–400 ms | 4 | 20 s |

### Event notify payload (`f00d0007`, 11 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | version = 1 |
| 1 | 1 | battery % |
| 2 | 2 | temperature °C×100 (`INT16_MIN` = NTC invalid) |
| 4 | 2 | bite_count (`0xFFFF` if link not L2-encrypted — privacy) |
| 6 | 1 | flags: VBUS, charging, NTC ok, IMU ok, meal |
| 7 | 4 | timestamp_ms |

Cadence: on change, and at least every **30 s** while event CCC is enabled.  
**iOS background:** subscribe to `f00d0007` only — do **not** leave bulk 10 Hz CCC on in background.  
**Foreground:** bulk `f00d0002` for IMU; keep event optional or dual-sub.

### Owner status payload (2 bytes)

Readable immediately after connect, before bonding:

| Byte | Meaning |
|---|---|
| `payload[0]` bit0 | `OWNER_PRESENT` — spoon already has an owner bond |
| `payload[0]` bit1 | `PEER_BONDED` — this phone is the stored owner |
| `payload[0]` bit2 | `PAIR_REJECTED` — pairing was refused on this link |
| `payload[0]` bit3 | `SECURED` — L2 encryption active |
| `payload[0]` bit4 | `REPAIR_HOLD_6S` — owner present and this peer is not owner |
| `payload[1]` | last `bt_security_err` reason (0 if none) |

If bit4 is set (or bit0 set and bit1 clear), show: **“Press and hold the spoon pad for 6 seconds to clear owner, then pair again.”** Do not spin forever on CCC/notify.

### TX notification payload (129 bytes, little-endian)

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | battery % | 0–100 |
| 1 | 2 | temperature | int16, °C × 100. **`0x8000` (`INT16_MIN`) = NTC disconnected / invalid** |
| 3 | 4 | timestamp_ms | uptime of first sample in batch |
| 7 | 2 | bite_count | uint16 |
| 9 | 120 | samples[10] | 10 × IMU sample, 10 ms apart |

Each IMU sample (12 B): `int16 ax,ay,az` in **milli-g**; `int16 gx,gy,gz` in **0.1 °/s** (covers ±2000 dps sensor FS). Decode gyro as `dps = wire / 10.0`.

RX supports only writes with response. Send one exact ASCII command:

- `OFF`
- `ON`
- `ON NN`, where `NN` is `30` through `70`

Do not use write-without-response. Treat an encryption ATT error as a request
to complete OS bonding, then rediscover services and retry once. Never retry
heater commands indefinitely.

Device ID is **open-read** so the app can identify a re-flashed spoon before
bonding. Hardware revision still requires an **encrypted** link and is the
characteristic used to start LESC Just Works. Treat the eight Device ID bytes
as an opaque stable identifier (lowercase hex). Hardware revision is an ASCII
compatibility value such as `A1`.

## Android

1. Request `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT` at runtime on Android 12+.
2. Connect with LE transport. Accessing an encrypted characteristic starts
   bonding, or call public `BluetoothDevice.createBond()` before service use.
3. Wait for `ACTION_BOND_STATE_CHANGED` to report `BOND_BONDED`.
4. Rediscover services after bonding.
5. Set the RX characteristic write type to `WRITE_TYPE_DEFAULT` and wait for
   `onCharacteristicWrite` before updating UI state.
6. Enable TX notifications only after bonding and verify descriptor-write
   completion.

Do not call `setPin()` or show a custom PIN UI — the firmware has no passkey.
Product advertising uses a **random static** address (privacy/RPA is off).
Prefer the bonded OS identity (`BluetoothDevice` / `CBPeripheral.identifier`)
plus the 8-byte Device ID (advertisement manufacturer data and open GATT
`f00d0004`) for durable product identity. Do not key cloud records solely by a
scanned MAC.

## iOS

CoreBluetooth has no public `pair()` API. Connect, discover, request TX
notifications or perform an RX write with `.withResponse`. iOS owns any system
pairing sheet (no numeric code to type for Just Works).

Persist `CBPeripheral.identifier`, not an observed BLE address. Handle
`CBATTError.insufficientEncryption` as a bond/reconnect state rather than a
generic network failure.

## OTA (MCUboot TEST + running-image self-confirm)

This is the Nordic / Zephyr standard: SMP over BLE, signed `zephyr.signed.bin`
only (never `merged.hex` or the DFU ZIP as the upload payload).

1. Bonded/encrypted link. SMP characteristics require encryption.
2. Read DIS firmware revision (`0x2A26`) for the UI. Optional: image-list.
3. Send heater `OFF` (RX write-with-response). Firmware rejects SMP chunks
   with `EBUSY` while the heater rail is on.
4. Download over **HTTPS**. Verify SHA-256, MCUboot magic `0x96f3b83d`, and
   size ≤ secondary slot (`0x79000`).
5. Release the app GATT client so MCUmgr owns the connection.
6. Upload, **TEST** (not permanent confirm of the inactive slot), then OS
   reset. Firmware `CONFIG_MCUMGR_GRP_IMG_ALLOW_CONFIRM_NON_ACTIVE_SLOT=n`.
7. Spoon TEST-boots without the touch gate, shows `DFU` during upload, then
   confirms itself after a 10 s healthy dwell (heater off, watchdogs, BLE,
   ADC, PMIC). Failure within 60 s reboots to roll back.
8. App reconnects after swap (~30 s). Do not send MCUmgr confirm from the
   phone; the running image confirms itself.

## Identity migration

Product BLE uses identity slot 1. If the spoon already has an owner bond, a
new phone is **rejected** until the owner long-holds (6 s) to clear the bond.
The long-hold **clears bonds only** and keeps the same static identity
address (MAC does not rotate). Then: forget the phone-side bond if needed,
pair again (Just Works, no PIN). Read the open owner-status characteristic
to detect this state. Never key a SaaS record by the advertising address —
use Device ID.

Connection supervision timeout requested by firmware is **20 s**. Prefer the
peripheral’s param-update timeout over assuming a hard-coded 5 s drop.
