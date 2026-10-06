#!/usr/bin/env python3
"""Train the SmartSpoon AI Lab eating model.

Input: labelled AI Lab recordings (spoon_session_*.csv, one person per file,
`user_bite_mark` = 1 on the sample the recorder tapped when the spoon reached
the mouth).

Output:
  smartspoon/assets/models/ai_lab_model.json          loaded by the app
  smartspoon/test/fixtures/ai_lab/<name>.csv.gz        two trimmed recordings
  smartspoon/test/fixtures/ai_lab/parity_golden.json   the Dart engine must
                                                       reproduce these numbers

This file and lib/features/ai_lab/domain/engine/*.dart both implement
docs/superpowers/specs/2026-09-11-ai-lab-eating-model-design.md. Change one,
change the other, re-run this script, then `flutter test test/ai_lab`.
"""
import argparse
import csv
import glob
import gzip
import json
import math
import os
from datetime import date

import numpy as np
from sklearn.linear_model import LogisticRegression

FS = 100                      # nominal IMU rate (Hz)
BACK, FWD, STEP = 250, 150, 10
GRAVITY_ALPHA = 0.01 / (0.15 + 0.01)
# Sample timestamps are the PHONE's receive time, so BLE delivering packets in
# bunches shows up as 1–2 s "gaps" followed by backwards steps with no data
# actually lost (person 1: 18 such gaps, ~100 samples/s throughout). Only a
# jump longer than this is a real stop in streaming.
GAP_RESET_MS = 5000
LABEL_HALF_WIDTH = 30         # decisions within ±0.3 s of a tap are "bite"
MATCH_TOL = 100               # a detection within ±1 s of a tap is correct
THRESHOLD = 0.35
# 2.5 s between accepted bites. Slow eaters linger at the mouth and make a
# second approach ~2 s after the real bite; 1.8 s counted those twice (held-out
# F1 0.954 → 0.963 at 2.5 s). The fastest real gap in the data is 2.9 s, so
# 2.5 s keeps a margin for quick eaters (2.8 s scored 0.972 but no margin).
MIN_GAP_DECISIONS = 25
VOTES_TO_DECIDE = 3
FFT_N = 256
STEADY_HOP = 100
BAND_HZ = (4.0, 12.0)
K_LO = math.ceil(BAND_HZ[0] * FFT_N / FS)
K_HI = math.floor(BAND_HZ[1] * FFT_N / FS)
HANN = 0.5 * (1.0 - np.cos(2.0 * np.pi * np.arange(FFT_N) / (FFT_N - 1)))

FEATURES = ['ang_b0.5', 'ang_b2.5', 'ang_f1.5', 'apex', 'gyro_back_mean',
            'gyro_back_max', 'gyro_fwd_max', 'rot_back', 'rot_fwd',
            'rbx', 'rby', 'rfz', 'reversal']
RBX, RFZ = FEATURES.index('rbx'), FEATURES.index('rfz')

FIXTURES = {'typical_eater': '2026-09-11T11-18-29',
            'slow_eater': '2026-09-11T11-36-10'}


# ── Loading ──────────────────────────────────────────────────────────────────

def load_recording(path):
    with open(path, newline='') as f:
        rows = list(csv.DictReader(f))
    return {
        'name': os.path.basename(path),
        'ts': np.array([int(r['timestamp_ms']) for r in rows], dtype=np.int64),
        'acc': np.array([[float(r['accelX']), float(r['accelY']),
                          float(r['accelZ'])] for r in rows]),
        'gyr': np.array([[float(r['gyroX']), float(r['gyroY']),
                          float(r['gyroZ'])] for r in rows]),
        'marks': np.where([r['user_bite_mark'] == '1' for r in rows])[0],
    }


def segments(ts):
    """[start, end) row ranges with no timestamp jump above GAP_RESET_MS."""
    cuts = [0] + [i for i in range(1, len(ts))
                  if ts[i] - ts[i - 1] > GAP_RESET_MS] + [len(ts)]
    return list(zip(cuts, cuts[1:]))


# ── Features (must match bite_features.dart) ─────────────────────────────────

def gravity(acc):
    g = np.empty_like(acc)
    s = acc[0].copy()
    for i in range(len(acc)):
        s = s + GRAVITY_ALPHA * (acc[i] - s)
        g[i] = s
    return g


def angle_deg(u, v):
    dot = u[0] * v[0] + u[1] * v[1] + u[2] * v[2]
    nu = math.sqrt(u[0] * u[0] + u[1] * u[1] + u[2] * u[2])
    nv = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    c = dot / (nu * nv + 1e-9)
    return math.acos(max(-1.0, min(1.0, c))) * 180.0 / math.pi


def segment_features(acc, gyr):
    """Decision sample indices, raw features and the hand-vote yaw for one
    gap-free segment. Indices are local to the segment."""
    g = gravity(acc)
    gm = np.sqrt((gyr ** 2).sum(1))
    idx = list(range(BACK, len(acc) - FWD, STEP))
    rows, yaw = [], []
    for t in idx:
        rb = gyr[t - 150:t].sum(0) / FS
        rf = gyr[t:t + 150].sum(0) / FS
        ang_f = angle_deg(g[t], g[t + 150])
        nb = math.sqrt(rb[0] ** 2 + rb[1] ** 2 + rb[2] ** 2)
        nf = math.sqrt(rf[0] ** 2 + rf[1] ** 2 + rf[2] ** 2)
        rows.append([
            angle_deg(g[t], g[t - 50]),
            angle_deg(g[t], g[t - 250]),
            ang_f,
            min(angle_deg(g[t], g[t - 150]), ang_f),
            gm[t - 150:t - 25].sum() / 125.0,
            gm[t - 150:t].max(),
            gm[t:t + 150].max(),
            gm[t - 200:t].sum() / FS,
            gm[t:t + 150].sum() / FS,
            rb[0], rb[1], rf[2],
            (rb[0] * rf[0] + rb[1] * rf[1] + rb[2] * rf[2]) / (nb * nf + 1e-9),
        ])
        yaw.append(rb[2])
    return (np.array(idx, dtype=np.int64),
            np.array(rows).reshape(-1, len(FEATURES)), np.array(yaw))


def for_mode(x, mode):
    x = x.copy()
    if mode == 'left':
        x[:, [RBX, RFZ]] *= -1.0
    elif mode == 'neutral':
        x[:, [RBX, RFZ]] = np.abs(x[:, [RBX, RFZ]])
    return x


def featurize(rec):
    """Cache: per segment (row offset, decision idx, raw features, yaw)."""
    out = []
    for a, b in segments(rec['ts']):
        if b - a <= BACK + FWD:
            continue
        idx, x, yaw = segment_features(rec['acc'][a:b], rec['gyr'][a:b])
        out.append((a, idx, x, yaw))
    return out


def labelled(rec, segs):
    xs, ys = [], []
    for a, idx, x, _ in segs:
        y = np.zeros(len(idx), dtype=int)
        for m in rec['marks']:
            y[np.abs(idx + a - m) <= LABEL_HALF_WIDTH] = 1
        xs.append(x)
        ys.append(y)
    return np.vstack(xs), np.concatenate(ys)


# ── Model ────────────────────────────────────────────────────────────────────

def fit(x, y):
    mean = x.mean(0)
    scale = x.std(0)
    scale[scale == 0] = 1.0
    clf = LogisticRegression(C=0.5, class_weight='balanced', max_iter=5000)
    clf.fit((x - mean) / scale, y)
    return {'mean': mean.tolist(), 'scale': scale.tolist(),
            'coef': clf.coef_[0].tolist(),
            'intercept': float(clf.intercept_[0])}


def predict(w, x):
    z = ((x - np.array(w['mean'])) / np.array(w['scale'])) @ np.array(w['coef'])
    return 1.0 / (1.0 + np.exp(-(z + w['intercept'])))


def replay(segs, w_right, w_neutral, hand='auto'):
    """The on-phone policy: neutral weights until 3 agreeing yaw votes decide
    the hand, then right weights (left = negated rbx/rfz). Returns detected
    bite rows (global), the decided hand and per-decision probabilities."""
    voting = hand == 'auto'
    decided = None if hand in ('auto', 'neutral') else hand
    votes, bites, trace = [], [], []
    for a, idx, x, yaw in segs:
        pr = predict(w_right, for_mode(x, 'right'))
        pl = predict(w_right, for_mode(x, 'left'))
        pn = predict(w_neutral, for_mode(x, 'neutral'))
        p, last = [], -10 ** 9
        for k in range(len(idx)):
            p.append(pn[k] if decided is None
                     else pr[k] if decided == 'right' else pl[k])
            trace.append((int(a + idx[k]), float(p[-1])))
            i = k - 2
            if i < 2:
                continue
            s = (p[i - 1] + p[i] + p[i + 1]) / 3.0
            if (s >= THRESHOLD
                    and s >= (p[i - 2] + p[i - 1] + p[i]) / 3.0
                    and s >= (p[i] + p[i + 1] + p[i + 2]) / 3.0
                    and i - last > MIN_GAP_DECISIONS):
                last = i
                bites.append(int(a + idx[i]))
                if voting and decided is None:
                    votes.append(1 if yaw[i] > 0 else -1)
                    tail = votes[-VOTES_TO_DECIDE:]
                    if len(tail) == VOTES_TO_DECIDE and abs(sum(tail)) == VOTES_TO_DECIDE:
                        decided = 'right' if tail[-1] > 0 else 'left'
    return bites, decided, trace


def score(det, marks):
    det, tp = list(det), 0
    for m in marks:
        if not det:
            break
        j = min(range(len(det)), key=lambda j: abs(det[j] - m))
        if abs(det[j] - m) <= MATCH_TOL:
            tp += 1
            det.pop(j)
    return tp, len(det), len(marks) - tp


# ── Steadiness (must match steadiness_analyzer.dart) ─────────────────────────

def steadiness_windows(gyr):
    """(local sample index, peak-line share of 4–12 Hz power, peak Hz)."""
    out = []
    for n in range(FFT_N - 1, len(gyr)):
        if n % STEADY_HOP:
            continue
        w = gyr[n - FFT_N + 1:n + 1]
        power = np.zeros(FFT_N // 2 + 1)
        for axis in range(3):
            x = w[:, axis]
            spec = np.fft.rfft((x - x.sum() / FFT_N) * HANN)
            power += spec.real ** 2 + spec.imag ** 2
        band = power[K_LO:K_HI + 1]
        k = int(np.argmax(band))
        total = band.sum()
        line = band[max(0, k - 1):k + 2].sum()
        out.append((n, float(line / total) if total > 0 else 0.0,
                    (K_LO + k) * FS / FFT_N))
    return out


def recording_windows(rec, gyr=None):
    gyr = rec['gyr'] if gyr is None else gyr
    out = []
    for a, b in segments(rec['ts']):
        out += [(a + n, c, f) for n, c, f in steadiness_windows(gyr[a:b])]
    return out


def steady_pct(windows, marks, threshold):
    lo, hi = marks[0] - 200, marks[-1] + 200
    meal = [c for n, c, _ in windows if lo <= n <= hi]
    return 100.0 * sum(c <= threshold for c in meal) / max(1, len(meal))


# ── Main ─────────────────────────────────────────────────────────────────────

def fmt(tp, fp, fn):
    return (f"F1={2 * tp / (2 * tp + fp + fn):.3f} recall={tp / (tp + fn):.3f} "
            f"precision={tp / max(1, tp + fp):.3f}")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--data', default=os.path.expanduser('~/Desktop/bites'))
    ap.add_argument('--app', default=os.path.join(here, '..', '..', 'smartspoon'))
    args = ap.parse_args()

    paths = sorted(glob.glob(os.path.join(args.data, 'spoon_session_*.csv')))
    if len(paths) < 3:
        raise SystemExit(f'need ≥3 recordings in {args.data}, found {len(paths)}')
    recs = [load_recording(p) for p in paths]
    segs = [featurize(r) for r in recs]
    data = [labelled(r, s) for r, s in zip(recs, segs)]
    n = len(recs)
    print(f'{n} people, {sum(len(r["marks"]) for r in recs)} labelled bites')

    # Leave-one-person-out: the tested person is never seen in training.
    print('\nleave-one-person-out (bite counted if within ±1 s of the tap)')
    totals = {'right': [0, 0, 0], 'neutral': [0, 0, 0], 'auto': [0, 0, 0]}
    counts = {k: [] for k in totals}
    hands = []
    for o in range(n):
        tr = [k for k in range(n) if k != o]
        x = np.vstack([data[k][0] for k in tr])
        y = np.concatenate([data[k][1] for k in tr])
        w_r = fit(x, y)
        w_n = fit(for_mode(x, 'neutral'), y)
        for mode in totals:
            det, decided, _ = replay(segs[o], w_r, w_n, mode)
            if mode == 'auto':
                hands.append(decided)
            counts[mode].append(len(det))
            totals[mode] = [a + b for a, b in
                            zip(totals[mode], score(det, recs[o]['marks']))]
    for mode, t in totals.items():
        print(f'  {mode:8s} {fmt(*t)} counts={counts[mode]}')
    print(f'  hand decided per person (auto): {hands}')

    # Steadiness reference from normal eaters.
    windows = [recording_windows(r) for r in recs]
    conc = np.array([c for w in windows for _, c, _ in w])
    chosen = None
    for q in (95.0, 97.5, 99.0):
        th = float(np.percentile(conc, q))
        pcts = [steady_pct(w, r['marks'], th) for w, r in zip(windows, recs)]
        if min(pcts) >= 90.0:
            chosen = (q, th, pcts)
            break
    if chosen is None:
        q, th = 99.0, float(np.percentile(conc, 99.0))
        chosen = (q, th, [steady_pct(w, r['marks'], th) for w, r in zip(windows, recs)])
    q, th, pcts = chosen
    print(f'\nsteadiness: rhythmic when peak-line share > {th:.3f} (normal P{q:g})')
    print(f'  normal steady % per person: {[round(p, 1) for p in pcts]}')
    rng = np.random.default_rng(3)
    synthetic = {}
    for amp in (10, 20):
        flagged = []
        for r in recs:
            t = np.arange(len(r['gyr'])) / FS
            axis = rng.normal(size=3)
            axis /= np.linalg.norm(axis)
            wave = amp * math.sqrt(2) * np.sin(2 * np.pi * 5.0 * t + rng.uniform(0, 6))
            w = recording_windows(r, r['gyr'] + np.outer(wave, axis))
            flagged.append(np.mean([c > th for _, c, _ in w]))
        synthetic[f'5Hz_{amp}dps'] = round(float(np.mean(flagged)), 3)
    print(f'  synthetic 5 Hz tremor, share of windows flagged: {synthetic}')

    # Final weights on everyone.
    x = np.vstack([d[0] for d in data])
    y = np.concatenate([d[1] for d in data])
    w_right, w_neutral = fit(x, y), fit(for_mode(x, 'neutral'), y)
    tp, fp, fn = totals['auto']
    model = {
        'version': 1,
        'trainedOn': date.today().isoformat(),
        'people': n,
        'bites': int(sum(len(r['marks']) for r in recs)),
        'features': FEATURES,
        'threshold': THRESHOLD,
        'minGapDecisions': MIN_GAP_DECISIONS,
        'votesToDecide': VOTES_TO_DECIDE,
        'right': w_right,
        'neutral': w_neutral,
        'evaluation': {
            'method': 'leave-one-person-out, ±1 s',
            'f1': round(2 * tp / (2 * tp + fp + fn), 3),
            'recall': round(tp / (tp + fn), 3),
            'precision': round(tp / max(1, tp + fp), 3),
            'countsPerPerson': counts['auto'],
            'bitesPerPerson': [int(len(r['marks'])) for r in recs],
        },
        'steadiness': {
            'fftSize': FFT_N,
            'hop': STEADY_HOP,
            'bandHz': list(BAND_HZ),
            'rhythmicShareThreshold': th,
            'normalPercentile': q,
            'normalSteadyPctMin': round(min(pcts), 1),
            'normalSteadyPctMedian': round(float(np.median(pcts)), 1),
            'syntheticDetection': synthetic,
        },
    }
    assets = os.path.join(args.app, 'assets', 'models')
    os.makedirs(assets, exist_ok=True)
    with open(os.path.join(assets, 'ai_lab_model.json'), 'w') as f:
        json.dump(model, f, indent=1)

    # Fixtures + parity golden (computed from the trimmed values themselves).
    fixdir = os.path.join(args.app, 'test', 'fixtures', 'ai_lab')
    os.makedirs(fixdir, exist_ok=True)
    golden = {}
    for label, stamp in FIXTURES.items():
        src = next((p for p in paths if stamp in p), None)
        if src is None:
            print(f'  fixture {stamp} not found, skipped')
            continue
        with open(src, newline='') as f:
            rows = list(csv.DictReader(f))
        lines = ['timestamp_ms,ax,ay,az,gx,gy,gz,mark']
        for r in rows:
            vals = [repr(float(r[k])) for k in
                    ('accelX', 'accelY', 'accelZ', 'gyroX', 'gyroY', 'gyroZ')]
            lines.append(','.join([r['timestamp_ms'], *vals, r['user_bite_mark']]))
        out = os.path.join(fixdir, f'{label}.csv.gz')
        with open(out, 'wb') as f:
            with gzip.GzipFile(fileobj=f, mode='wb', mtime=0) as gz:
                gz.write(('\n'.join(lines) + '\n').encode())
        rec = load_recording(src)
        fsegs = featurize(rec)
        bites_auto, hand_auto, _ = replay(fsegs, w_right, w_neutral, 'auto')
        bites_right, _, _ = replay(fsegs, w_right, w_neutral, 'right')
        decisions = []
        for a, idx, xs, yaw in fsegs:
            pr = predict(w_right, for_mode(xs, 'right'))
            pn = predict(w_neutral, for_mode(xs, 'neutral'))
            for k in range(0, len(idx), 4):
                decisions.append({'row': int(a + idx[k]),
                                  'features': xs[k].tolist(),
                                  'yaw': float(yaw[k]),
                                  'pRight': float(pr[k]),
                                  'pNeutral': float(pn[k])})
        golden[label] = {
            'file': f'{label}.csv.gz',
            'marks': [int(m) for m in rec['marks']],
            'decisions': decisions,
            'bitesAuto': bites_auto,
            'handAuto': hand_auto,
            'bitesRight': bites_right,
            'steadiness': [{'row': int(nn), 'share': c, 'hz': fz}
                           for nn, c, fz in recording_windows(rec)],
        }
        print(f'  fixture {label}: {len(rec["marks"])} taps, '
              f'{len(bites_auto)} detected (auto, hand={hand_auto})')
    with open(os.path.join(fixdir, 'parity_golden.json'), 'w') as f:
        json.dump(golden, f)
    print(f'\nwrote {os.path.join(assets, "ai_lab_model.json")} and fixtures in {fixdir}')


if __name__ == '__main__':
    main()
