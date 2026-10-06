// Multi-spoon scenario suite.
//
// One test per case in "Multi-Spoon Connection Scenarios & App Logic", named
// with its case number so a failure points straight at the product rule it
// broke. The invariant behind all of them: exactly ONE spoon may be STREAMING.
//
// Real time, not fakeAsync — see the note in ble_connection_coordinator_test.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smartspoon/ble/connection_coordinator.dart';
import 'package:smartspoon/ble/device_authenticator.dart';
import 'package:smartspoon/ble/device_registry.dart';
import 'package:smartspoon/ble/meal_session_guard.dart';
import 'package:smartspoon/ble/models/spoon_models.dart';
import 'package:smartspoon/ble/primary_reclaim_monitor.dart';

import 'ble_connection_coordinator_test.dart'
    show FakeAdvert, FakeTransport, identityBytesFor, pumpUntil, quiet;

const String pidA = 'aaaaaaaaaaaaaaa1';
const String pidB = 'bbbbbbbbbbbbbbb2';
const String pidC = 'cccccccccccccc03';
const String pidD = 'dddddddddddddd04';

SpoonRecord spoon(
  String pid, {
  bool isPrimary = false,
  String? remoteId,
  DateTime? lastConnectedAt,
  String name = 'iSpoon',
}) =>
    SpoonRecord(
      spoonSerial: pid,
      publicDeviceId: pid,
      bleRemoteId: remoteId,
      displayName: name,
      isPrimary: isPrimary,
      lastConnectedAt: lastConnectedAt,
    );

class Scene {
  Scene(this.transport, this.registry, this.mealGuard, this.reclaim,
      this.coordinator);

  final FakeTransport transport;
  final DeviceRegistry registry;
  final MealSessionGuard mealGuard;
  final PrimaryReclaimMonitor reclaim;
  final ConnectionCoordinator coordinator;

  static Future<Scene> create(
    List<SpoonRecord> records, {
    Duration? mealBudget,
    int? mealAttempts,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final registry = DeviceRegistry(prefs: prefs);
    await registry.load();
    for (final r in records) {
      await registry.upsert(r);
      if (r.isPrimary) await registry.setPrimary(r.spoonSerial);
    }
    final transport = FakeTransport();
    final mealGuard = MealSessionGuard(
      reconnectBudget: mealBudget,
      maxAttempts: mealAttempts,
    );
    final reclaim = PrimaryReclaimMonitor();
    return Scene(
      transport,
      registry,
      mealGuard,
      reclaim,
      ConnectionCoordinator(
        registry: registry,
        authenticator: DeviceAuthenticator(),
        mealGuard: mealGuard,
        reclaimMonitor: reclaim,
        transport: transport,
        backgroundUsesOsStandby: true,
      ),
    );
  }

  /// Make [pids] answer identity reads and advertise.
  void present(Map<String, String> remoteIdToPid, {int rssi = -55}) {
    transport.adverts = [
      for (final e in remoteIdToPid.entries)
        FakeAdvert(remoteId: e.key, deviceId: e.value, rssi: rssi),
    ];
    for (final e in remoteIdToPid.entries) {
      transport.identity[e.key] = identityBytesFor(e.value);
    }
  }

  String? get activeSerial => coordinator.activeSpoon?.spoonSerial;
  void dispose() => coordinator.dispose();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  // ── 1. Initial startup & selection ─────────────────────────────────────

  test('1.1 only Spoon A is saved and available → A streams', () async {
    final s = await Scene.create([spoon(pidA)]);
    s.present({'ble-a': pidA});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial == pidA);
    expect(s.activeSerial, pidA);
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('1.2 A (primary) and B both available → primary A wins', () async {
    final s = await Scene.create([spoon(pidA, isPrimary: true), spoon(pidB)]);
    // B is louder, to prove the primary bonus outranks signal (§9.3).
    s.transport.adverts = [
      FakeAdvert(remoteId: 'ble-b', deviceId: pidB, rssi: -40),
      FakeAdvert(remoteId: 'ble-a', deviceId: pidA, rssi: -75),
    ];
    s.transport.identity['ble-a'] = identityBytesFor(pidA);
    s.transport.identity['ble-b'] = identityBytesFor(pidB);

    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial != null);
    expect(s.activeSerial, pidA);
    expect(s.transport.connectCalls, ['ble-a']);
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('1.3 no primary; B was used yesterday → B wins over never-used A/C',
      () async {
    final yesterday = DateTime.now().subtract(const Duration(hours: 20));
    final s = await Scene.create([
      spoon(pidA),
      spoon(pidB, lastConnectedAt: yesterday),
      spoon(pidC),
    ]);
    s.present({'ble-a': pidA, 'ble-b': pidB, 'ble-c': pidC});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial != null);
    expect(s.activeSerial, pidB,
        reason: 'last-used outranks never-used when no primary is set');
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── 2. Active spoon dies (fallback) ────────────────────────────────────

  test('2.1 primary A dies and B is on → fallback to B', () async {
    final s = await Scene.create(
        [spoon(pidA, isPrimary: true, remoteId: 'ble-a'), spoon(pidB)]);
    s.present({'ble-a': pidA, 'ble-b': pidB});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial == pidA);

    // A dies and stops advertising.
    s.transport.refuseConnect.add('ble-a');
    s.transport.adverts = [FakeAdvert(remoteId: 'ble-b', deviceId: pidB)];
    s.transport.dropLink('ble-a');

    await pumpUntil(() => s.activeSerial == pidB,
        timeout: const Duration(seconds: 40));
    expect(s.activeSerial, pidB);
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('2.2 A dies; B used 10 min ago beats C used yesterday', () async {
    final s = await Scene.create([
      spoon(pidA, isPrimary: true, remoteId: 'ble-a'),
      spoon(pidB, lastConnectedAt: DateTime.now().subtract(const Duration(minutes: 5))),
      spoon(pidC, lastConnectedAt: DateTime.now().subtract(const Duration(hours: 20))),
    ]);
    s.present({'ble-a': pidA, 'ble-b': pidB, 'ble-c': pidC});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial == pidA);

    s.transport.refuseConnect.add('ble-a');
    s.transport.adverts = [
      FakeAdvert(remoteId: 'ble-b', deviceId: pidB),
      FakeAdvert(remoteId: 'ble-c', deviceId: pidC),
    ];
    s.transport.dropLink('ble-a');

    await pumpUntil(() => s.activeSerial == pidB,
        timeout: const Duration(seconds: 40));
    expect(s.activeSerial, pidB, reason: 'recent use outranks older use');
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('2.3 A dies and nothing else is on → backoff retry, no wrong link',
      () async {
    final s = await Scene.create([spoon(pidA, remoteId: 'ble-a')]);
    s.present({'ble-a': pidA});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial == pidA);

    s.transport.refuseConnect.add('ble-a');
    s.transport.adverts = [];
    s.transport.dropLink('ble-a');
    await pumpUntil(() => s.activeSerial == null);

    await quiet(const Duration(seconds: 8));
    expect(s.activeSerial, isNull);
    expect(s.transport.scanCount, greaterThan(0),
        reason: 'it must keep looking, on a growing backoff');
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ── 3. Primary returns (reclaim policy) ────────────────────────────────
  // The reclaim cadence is a 60 s timer plus a 9 s scan plus a 7 s grace, so
  // these assert the decision itself rather than waiting out the schedule.

  test('3.1 fallback active, primary stable, no meal → reclaim allowed',
      () async {
    final m = PrimaryReclaimMonitor(grace: const Duration(milliseconds: 50));
    // Grace measures OBSERVED stability, so the spoon has to keep being seen
    // across it. One advertisement followed by silence is edge case #11 — the
    // single distant blip the grace exists to reject — and is covered by 3.4.
    for (var i = 0; i < 8; i++) {
      m.observePrimary(isStable: true);
      await quiet(const Duration(milliseconds: 10));
    }
    expect(
      m.evaluate(
        primarySerial: pidA,
        activeSerial: pidB,
        mealActive: false,
        coordinatorBusy: false,
      ),
      ReclaimBlockReason.allowed,
    );
  });

  test('3.4 a single blip of the primary never meets grace (edge case #11)',
      () async {
    final m = PrimaryReclaimMonitor(grace: const Duration(milliseconds: 50));
    m.observePrimary(isStable: true);
    await quiet(const Duration(milliseconds: 200));
    expect(
      m.evaluate(
        primarySerial: pidA,
        activeSerial: pidB,
        mealActive: false,
        coordinatorBusy: false,
      ),
      ReclaimBlockReason.primaryNotStableYet,
      reason: 'time passing while the radio is idle is not evidence of '
          'stability; only further sightings are',
    );
  });

  test('3.2 primary returns during an active meal → never switch', () async {
    final m = PrimaryReclaimMonitor(grace: const Duration(milliseconds: 50));
    m.observePrimary(isStable: true);
    await quiet(const Duration(milliseconds: 80));
    expect(
      m.evaluate(
        primarySerial: pidA,
        activeSerial: pidB,
        mealActive: true,
        coordinatorBusy: false,
      ),
      ReclaimBlockReason.mealActive,
    );
  });

  test('3.3 manual override cooldown blocks reclaim', () async {
    final m = PrimaryReclaimMonitor(grace: const Duration(milliseconds: 50));
    m.recordManualOverride(pidB);
    m.observePrimary(isStable: true);
    await quiet(const Duration(milliseconds: 80));
    expect(
      m.evaluate(
        primarySerial: pidA,
        activeSerial: pidB,
        mealActive: false,
        coordinatorBusy: false,
      ),
      ReclaimBlockReason.manualOverrideCooldown,
    );
    expect(m.manualOverrideSerial, pidB);
  });

  // ── 4. Active-meal safety ──────────────────────────────────────────────

  test('4.1 meal spoon dies with B available → never silently switch; pause '
      'after the budget', () async {
    final s = await Scene.create(
      [spoon(pidA, remoteId: 'ble-a'), spoon(pidB, remoteId: 'ble-b')],
      mealBudget: const Duration(seconds: 3),
      mealAttempts: 2,
    );
    s.present({'ble-a': pidA, 'ble-b': pidB});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial == pidA);

    String? pausedFor;
    s.coordinator.onMealPaused = (serial) => pausedFor = serial;
    expect(s.coordinator.startMeal(), isTrue);

    // A dies; B stays on and advertising.
    s.transport.refuseConnect.add('ble-a');
    s.transport.adverts = [FakeAdvert(remoteId: 'ble-b', deviceId: pidB)];
    s.transport.dropLink('ble-a');

    await pumpUntil(() => pausedFor != null,
        timeout: const Duration(seconds: 40));

    expect(pausedFor, pidA, reason: 'the user must be asked, not switched');
    expect(s.activeSerial, isNull);
    expect(s.transport.connectCalls.contains('ble-b'), isFalse,
        reason: 'Rule 5 — B must never be connected without confirmation');
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('4.2 user confirms switch to B during paused meal → connects to B',
      () async {
    final s = await Scene.create(
      [spoon(pidA, remoteId: 'ble-a'), spoon(pidB, remoteId: 'ble-b')],
      mealBudget: const Duration(seconds: 2),
      mealAttempts: 1,
    );
    s.present({'ble-a': pidA, 'ble-b': pidB});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial == pidA);
    s.coordinator.startMeal();

    s.transport.refuseConnect.add('ble-a');
    s.transport.dropLink('ble-a');
    await pumpUntil(() => s.mealGuard.isPaused,
        timeout: const Duration(seconds: 30));

    // User explicitly confirms switch to B
    await s.coordinator.confirmMealSwitch(pidB);
    await pumpUntil(() => s.activeSerial == pidB,
        timeout: const Duration(seconds: 30));

    expect(s.activeSerial, pidB);
    expect(s.coordinator.state, SpoonState.streaming);
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('4.3 meal paused and user ignores the prompt → B stays unconnected',
      () async {
    final s = await Scene.create(
      [spoon(pidA, remoteId: 'ble-a'), spoon(pidB, remoteId: 'ble-b')],
      mealBudget: const Duration(seconds: 2),
      mealAttempts: 1,
    );
    s.present({'ble-a': pidA, 'ble-b': pidB});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial == pidA);
    s.coordinator.startMeal();

    s.transport.refuseConnect.add('ble-a');
    s.transport.dropLink('ble-a');
    await pumpUntil(() => s.mealGuard.isPaused,
        timeout: const Duration(seconds: 30));

    await quiet(const Duration(seconds: 6));
    expect(s.mealGuard.isPaused, isTrue);
    expect(s.transport.connectCalls.contains('ble-b'), isFalse);
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ── 5. Manual switching & races ────────────────────────────────────────

  test('5.1 manual switch A → B, and the choice is remembered', () async {
    final s = await Scene.create(
        [spoon(pidA, isPrimary: true, remoteId: 'ble-a'), spoon(pidB, remoteId: 'ble-b')]);
    s.present({'ble-a': pidA, 'ble-b': pidB});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial == pidA);

    final switched = Stopwatch()..start();
    await s.coordinator.selectSpoon(pidB);
    await pumpUntil(() => s.activeSerial == pidB);
    switched.stop();

    expect(s.activeSerial, pidB);
    expect(switched.elapsed, lessThan(const Duration(seconds: 2)),
        reason: 'A→B switch must not pay sequential GATT cancel timeouts');
    expect(s.reclaim.manualOverrideSerial, pidB,
        reason: 'the manual choice must outrank the primary for its cooldown');
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('5.2 a manual tap outranks and aborts an in-flight auto attempt',
      () async {
    final s = await Scene.create([
      spoon(pidB, remoteId: 'ble-b'),
      spoon(pidC, remoteId: 'ble-c'),
    ]);
    s.present({'ble-b': pidB, 'ble-c': pidC});

    // Start the automatic path, then immediately demand C.
    unawaited(s.coordinator.initialize());
    unawaited(s.coordinator.selectSpoon(pidC));

    await pumpUntil(() => s.activeSerial != null,
        timeout: const Duration(seconds: 40));
    expect(s.activeSerial, pidC,
        reason: 'manualConfirmed (1000) outranks startup (600)');
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('5.3 forget active spoon A → tears down and never reconnects to A',
      () async {
    final s = await Scene.create([
      spoon(pidA, remoteId: 'ble-a'),
      spoon(pidB, remoteId: 'ble-b'),
    ]);
    s.present({'ble-a': pidA, 'ble-b': pidB});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial == pidA);

    await s.coordinator.forgetSpoon(pidA);
    await pumpUntil(() => s.activeSerial != pidA);

    expect(s.registry.byId(pidA), isNull);
    expect(s.transport.disconnectCalls, contains('ble-a'));
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── 6. Background / restart reconciliation ─────────────────────────────

  test('6.1b background range-loss of A → standby keeps waiting for A, not B',
      () async {
    final s = await Scene.create([
      spoon(pidA, remoteId: 'ble-a'),
      spoon(pidB, remoteId: 'ble-b'),
    ]);
    s.present({'ble-a': pidA, 'ble-b': pidB});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial == pidA);

    s.coordinator.onAppPaused();

    // A timed out (phone and spoon drifted apart) — nothing says it is off.
    // Spoon = person: arming B here meant the user's own spoon never came
    // back in the background once they walked back into range.
    s.transport.refuseConnect.add('ble-a');
    s.transport.dropLink('ble-a');

    await pumpUntil(() => s.transport.armed.isNotEmpty,
        timeout: const Duration(seconds: 15));
    expect(s.transport.armed, {'ble-a'});

    s.transport.refuseConnect.remove('ble-a');
    s.transport.fireArmedLink('ble-a');
    await pumpUntil(() => s.activeSerial == pidA,
        timeout: const Duration(seconds: 40));
    expect(s.activeSerial, pidA);
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('6.1 background drop of A → coordinator recovers to saved B',
      () async {
    final s = await Scene.create([
      spoon(pidA, remoteId: 'ble-a'),
      spoon(pidB, remoteId: 'ble-b'),
    ]);
    s.present({'ble-a': pidA, 'ble-b': pidB});
    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial == pidA);

    // App goes to background: drops bulk telemetry, keeps link
    s.coordinator.onAppPaused();

    // Spoon A is SWITCHED OFF in background (firmware sends a clean terminate
    // before System OFF); B is advertising. Standby arms exactly one other
    // saved spoon (not A and B together).
    s.transport.deliberateDrops.add('ble-a');
    s.transport.refuseConnect.add('ble-a');
    s.transport.adverts = [FakeAdvert(remoteId: 'ble-b', deviceId: pidB)];
    s.transport.dropLink('ble-a');

    await pumpUntil(() => s.transport.armed.contains('ble-b'),
        timeout: const Duration(seconds: 15));
    s.transport.fireArmedLink('ble-b');

    await pumpUntil(() => s.activeSerial == pidB,
        timeout: const Duration(seconds: 40));
    expect(s.activeSerial, pidB);
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('6.2 cold start with stray OS links → adopt one, close the rest',
      () async {
    final s = await Scene.create([
      spoon(pidA, isPrimary: true, remoteId: 'ble-a'),
      spoon(pidB, remoteId: 'ble-b'),
    ]);
    s.present({'ble-a': pidA, 'ble-b': pidB});
    // The OS still holds links from a previous process: our primary, our
    // fallback, and a stranger's device.
    s.transport.preConnected = ['ble-a', 'ble-b', 'ble-stranger'];

    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial != null);
    await quiet(const Duration(seconds: 1));

    expect(s.activeSerial, pidA, reason: 'adopt the primary, do not re-scan');
    // Rule 1 — every other open link must be closed, not left dangling on a
    // GATT slot with its spoon still showing "connected".
    expect(s.transport.disconnectCalls, contains('ble-b'));
    expect(s.transport.disconnectCalls, contains('ble-stranger'));
    expect(s.transport.disconnectCalls.contains('ble-a'), isFalse);
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── Add Spoon (claim) ──────────────────────────────────────────────────

  test('Add Spoon: a stale phone bond is cleared and the claim still succeeds',
      () async {
    final s = await Scene.create(const <SpoonRecord>[]); // nothing saved yet
    s.transport.identity['ble-new'] = identityBytesFor(pidA);
    s.transport.owner['ble-new'] = [0x00, 0x00]; // unowned, ready to claim
    s.transport.refuseBond.add('ble-new');
    // Firmware records PAIR_REJECTED — this phone is offering a dead key.
    s.transport.ownerAfterFailedBond['ble-new'] = [0x04, 0x08];

    await s.coordinator.initialize();
    final result = await s.coordinator.claimSpoon(
      bleRemoteId: 'ble-new',
      displayName: 'iSpoon Pro',
    );

    expect(s.transport.clearBondCalls, contains('ble-new'),
        reason: 'the app must delete the dead bond, not blame the user');
    expect(result.isSuccess, isTrue,
        reason: 'the claim recovers by itself after clearing and re-pairing');
    expect(s.registry.byId(pidA), isNotNull);
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('Add Spoon: an unfinished bond says "try again", not "refused"',
      () async {
    final s = await Scene.create(const <SpoonRecord>[]);
    s.transport.identity['ble-new'] = identityBytesFor(pidA);
    // OWNER_PRESENT + PEER_BONDED: this phone already owns the spoon, so
    // nothing is refusing anything — the handshake just did not finish. A
    // timeout, a busy stack, an unanswered prompt.
    s.transport.owner['ble-new'] = [0x03, 0x00];
    s.transport.refuseBond.add('ble-new');

    await s.coordinator.initialize();
    final result = await s.coordinator.claimSpoon(bleRemoteId: 'ble-new');

    expect(result.isSuccess, isFalse);
    expect(result.outcome, ClaimOutcome.connectFailed,
        reason: 'an incomplete bond is not "someone else owns this spoon"');
    expect(result.detail, contains('try again'));
    expect(s.registry.byId(pidA), isNull,
        reason: 'nothing is saved for a spoon we never took ownership of');
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('Add Spoon: a spoon owned by another phone asks for the 6-second hold',
      () async {
    final s = await Scene.create(const <SpoonRecord>[]);
    s.transport.identity['ble-new'] = identityBytesFor(pidA);
    // OWNER_PRESENT + REPAIR_HOLD_6S, PEER_BONDED clear.
    s.transport.owner['ble-new'] = [0x11, 0x00];
    s.transport.refuseBond.add('ble-new');

    await s.coordinator.initialize();
    final result = await s.coordinator.claimSpoon(bleRemoteId: 'ble-new');

    // The authenticator catches this from the owner-status read BEFORE any
    // bond is attempted, which is the cheapest possible place to catch it.
    expect(result.outcome, ClaimOutcome.alreadyClaimedByOther);
    expect(result.detail?.toLowerCase(), contains('6s'),
        reason: 'the message must name the physical fix, not a generic error');
    expect(s.transport.clearBondCalls, isEmpty,
        reason: 'this is the spoon refusing, not our bond store');
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('Add Spoon while a saved spoon is auto-connecting: the tap wins and the '
      'claim is never "superseded"', () async {
    // Exactly the on-screen situation: a saved spoon is mid-reconnect (the card
    // reads "Discovering services…") and the user taps + on a nearby spoon.
    final s = await Scene.create([spoon(pidB, remoteId: 'ble-b')]);
    s.transport.identity['ble-b'] = identityBytesFor(pidB);
    s.transport.identity['ble-new'] = identityBytesFor(pidA);
    s.transport.owner['ble-new'] = [0x00, 0x00]; // unowned, ready to claim
    s.transport.adverts = [FakeAdvert(remoteId: 'ble-b', deviceId: pidB)];

    // Kick the automatic path and immediately claim, without awaiting.
    unawaited(s.coordinator.initialize());
    final result = await s.coordinator.claimSpoon(
      bleRemoteId: 'ble-new',
      displayName: 'iSpoon Pro',
    );

    expect(result.isSuccess, isTrue,
        reason: 'background reconnect must not abort a pairing the user '
            'started — that produced a bare "superseded" on screen');
    expect(s.registry.byId(pidA), isNotNull);
    expect(result.detail ?? '', isNot(contains('superseded')));
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a failed operation never leaves the UI stuck on a transitional state',
      () async {
    // Nothing answers: no adverts, no identity. The pipeline must still land
    // somewhere the user can act on, not sit on "Discovering services…".
    final s = await Scene.create([spoon(pidA, remoteId: 'ble-a')]);
    s.transport.refuseConnect.add('ble-a');

    unawaited(s.coordinator.initialize());

    // Wait until it has actually tried, or the assertion passes on the initial
    // state before anything has happened.
    await pumpUntil(() => s.coordinator.state.isTransitional,
        timeout: const Duration(seconds: 20));

    // Retries keep cycling by design, so "never transitional" is not the
    // invariant — "never STUCK transitional" is. It must come back to a state
    // the user can read and act on.
    await pumpUntil(
        () => !s.coordinator.state.isTransitional &&
            s.coordinator.lastDisconnectReason != null,
        timeout: const Duration(seconds: 40));

    expect(s.coordinator.state.isTransitional, isFalse,
        reason: 'a transitional state with nothing running is a spinner that '
            'never ends');
    expect(s.coordinator.lastDisconnectReason, isNotNull,
        reason: 'and it carries a reason the UI can explain');
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('Add Spoon: a free spoon that still refuses SMP is reported as a '
      'firmware problem, not a phone problem', () async {
    // Exactly what the Vivo logs showed: spoon reports owner=false,
    // rejected=false; this phone holds no bond; SMP still fails with
    // AUTH_FAIL. Telling the user to forget a device that was never in their
    // Bluetooth list sends them chasing a fault that is not theirs.
    final s = await Scene.create(const <SpoonRecord>[]);
    s.transport.identity['ble-new'] = identityBytesFor(pidA);
    s.transport.owner['ble-new'] = [0x00, 0x00];
    s.transport.refuseBond.add('ble-new');
    s.transport.phoneHoldsBond = false;

    await s.coordinator.initialize();
    final result = await s.coordinator.claimSpoon(bleRemoteId: 'ble-new');

    expect(result.isSuccess, isFalse);
    expect(s.transport.clearBondCalls, isEmpty,
        reason: 'there is no key to clear — do not pretend otherwise');
    expect(result.detail, contains('firmware'),
        reason: 'name the real fault so it can be fixed');
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('5.4 tapping spoon A then spoon B connects to B — the LAST tap wins',
      () async {
    // Both taps are manualConfirmed (priority 1000). A strict > comparison
    // discarded the second as "outranked", so the app connected to whichever
    // spoon was tapped FIRST and ignored the one the user actually wanted.
    final s = await Scene.create([
      spoon(pidA, remoteId: 'ble-a'),
      spoon(pidB, remoteId: 'ble-b'),
    ]);
    s.present({'ble-a': pidA, 'ble-b': pidB});
    await s.coordinator.initialize();

    unawaited(s.coordinator.selectSpoon(pidA));
    await quiet(const Duration(milliseconds: 150));
    unawaited(s.coordinator.selectSpoon(pidB));

    await pumpUntil(() => s.activeSerial == pidB,
        timeout: const Duration(seconds: 40));
    expect(s.activeSerial, pidB,
        reason: 'the most recent tap carries the current intention');
    expect(s.coordinator.state, SpoonState.streaming);
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  // ── 7. Identity & security ─────────────────────────────────────────────

  test('7.1 two spoons share a BLE name → identity decides, not the name',
      () async {
    final s = await Scene.create([
      spoon(pidB, remoteId: 'ble-b', name: 'SmartSpoon'),
    ]);
    // Both advertise the SAME name; only the device id differs.
    s.transport.adverts = [
      FakeAdvert(remoteId: 'ble-x', deviceId: pidD, name: 'SmartSpoon'),
      FakeAdvert(remoteId: 'ble-b', deviceId: pidB, name: 'SmartSpoon'),
    ];
    s.transport.identity['ble-b'] = identityBytesFor(pidB);
    s.transport.identity['ble-x'] = identityBytesFor(pidD);

    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.activeSerial != null);

    expect(s.activeSerial, pidB);
    expect(s.transport.connectCalls.contains('ble-x'), isFalse,
        reason: 'the unsaved twin must never be connected');
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('7.2 spoon was owner-reset → blocked for re-claim, not streamed',
      () async {
    final s = await Scene.create([spoon(pidA, remoteId: 'ble-a')]);
    s.present({'ble-a': pidA});
    // Owner cleared by the 6-second long hold: OWNER_PRESENT = 0.
    s.transport.owner['ble-a'] = [0x00, 0x00];

    unawaited(s.coordinator.initialize());
    await pumpUntil(() => s.coordinator.state == SpoonState.unclaimed ||
        s.coordinator.state == SpoonState.requiresReclaim);

    expect(s.activeSerial, isNull, reason: 'no telemetry from a reset spoon');
    expect(
      s.coordinator.state,
      anyOf(SpoonState.unclaimed, SpoonState.requiresReclaim),
    );
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('7.3 an unknown spoon nearby is ignored by auto-connect', () async {
    final s = await Scene.create([spoon(pidA, remoteId: 'ble-a')]);
    s.transport.adverts = [
      FakeAdvert(remoteId: 'ble-d', deviceId: pidD),
    ];
    s.transport.identity['ble-d'] = identityBytesFor(pidD);

    unawaited(s.coordinator.initialize());
    await quiet(const Duration(seconds: 12));

    // Rule 7 — the unknown spoon is not a lesser candidate, it is not a
    // candidate. (The saved spoon's own cached locator may be tried per §10.2;
    // that is a different rule and the fake radio answers it, so assert on the
    // stranger specifically.)
    expect(s.transport.connectCalls.contains('ble-d'), isFalse);
    expect(s.activeSerial, isNot(pidD));
    s.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
