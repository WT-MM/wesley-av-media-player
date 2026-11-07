#!/usr/bin/env python3
"""Analyze independent, bracketed whole-Mac discharge measurements.

Windows JSON: [{"profile":"wam-float32", "round":0,
 "idle_before":[start,end], "recording":[start,end], "idle_after":[start,end]}]
Use epoch seconds; minimum 180s per window, 5 rounds per profile. No app control.
"""
import argparse
import json
import math
import random
import statistics
from collections import defaultdict
from itertools import combinations
from pathlib import Path


def window_power(samples, interval):
    start, end = interval
    if not (math.isfinite(start) and math.isfinite(end)) or end - start < 180:
        raise ValueError('Each window must contain at least 180 steady seconds')
    rows = sorted((r for r in samples if start <= r['unix'] <= end), key=lambda r: r['unix'])
    if len(rows) < 10 or rows[0]['unix'] - start > 5 or end - rows[-1]['unix'] > 5:
        raise ValueError('Insufficient telemetry coverage')
    power = []
    updates = set()
    for row in rows:
        if row.get('ExternalConnected') is not False or row.get('IsCharging') is not False:
            raise ValueError('Charging, external power, or unknown power state invalidates a window')
        current, voltage = row.get('Amperage'), row.get('Voltage')
        if not isinstance(current, (int, float)) or not isinstance(voltage, (int, float)) or not math.isfinite(current) or not math.isfinite(voltage) or not current < 0 or not 8000 < voltage < 16000:
            raise ValueError('Invalid discharge telemetry')
        power.append(-current * voltage / 1e6)
        updates.add((row.get('UpdateTime'), current, voltage))
    if len(updates) < 10:
        raise ValueError('Battery telemetry did not update sufficiently')
    energy = 0
    for i in range(1, len(rows)):
        dt = rows[i]['unix'] - rows[i - 1]['unix']
        if not 0 < dt <= 10:
            raise ValueError('Telemetry gap or duplicate timestamp')
        energy += dt * (power[i] + power[i - 1]) / 2
    return energy / (rows[-1]['unix'] - rows[0]['unix'])


def interval(values):
    # Resample independent recording blocks, never individual battery gauge rows.
    rng = random.Random(72631)
    draws = sorted(statistics.mean(rng.choices(values, k=len(values))) for _ in range(10000))
    return [draws[250], draws[9749]]


def analyze(samples, windows, capacity_wh):
    if not math.isfinite(capacity_wh) or capacity_wh <= 0:
        raise ValueError('Battery capacity must be positive')
    grouped = defaultdict(list)
    paired = defaultdict(dict)
    seen = set()
    occupied = []
    for block in windows:
        key = block['profile'], block['round']
        if key in seen:
            raise ValueError('Duplicate profile/round')
        seen.add(key)
        spans = [block[k] for k in ('idle_before', 'recording', 'idle_after')]
        if not spans[0][1] <= spans[1][0] or not spans[1][1] <= spans[2][0]:
            raise ValueError('Idle windows must bracket the recording')
        occupied.extend(spans)
        before, recording, after = [window_power(samples, span) for span in spans]
        # Interpolate baseline at the recording midpoint to account for linear drift.
        centers = [sum(span) / 2 for span in spans]
        fraction = (centers[1] - centers[0]) / (centers[2] - centers[0])
        baseline = before + (after - before) * fraction
        grouped[block['profile']].append(recording - baseline)
        paired[block['profile']][block['round']] = recording - baseline
    occupied.sort()
    if any(a[1] > b[0] for a, b in zip(occupied, occupied[1:])):
        raise ValueError('Measurement windows overlap; independent blocks are required')
    result = {}
    for profile, deltas in grouped.items():
        if len(deltas) < 5:
            raise ValueError('At least five independent blocks per profile are required')
        bounds = interval(deltas)
        mean = statistics.mean(deltas)
        result[profile] = dict(rounds=len(deltas), incremental_watts=mean,
            bootstrap_95_percent_interval_watts=bounds,
            resolved_positive_draw=bounds[0] > 0,
            raw_90min_battery_percentage_points=mean * 1.5 / capacity_wh * 100,
            note='Conditional on matched workload; bootstrap interval excludes systematic meter error. Negative or zero-crossing deltas do not establish savings.')
    comparisons = []
    for first, second in combinations(sorted(paired), 2):
        rounds = sorted(paired[first].keys() & paired[second].keys())
        if len(rounds) < 5:
            continue
        differences = [paired[first][r] - paired[second][r] for r in rounds]
        bounds = interval(differences)
        comparisons.append(dict(first=first, second=second, rounds=len(rounds),
            first_minus_second_watts=statistics.mean(differences),
            bootstrap_95_percent_interval_watts=bounds,
            lower_measured_draw=first if bounds[1] < 0 else second if bounds[0] > 0 else "unresolved"))
    return dict(profiles=result, paired_comparisons=comparisons,
        limitation="Controlled workload and matched capture settings must be established separately; these intervals do not include systematic measurement error.")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--battery', type=Path, required=True)
    parser.add_argument('--windows', type=Path, required=True)
    parser.add_argument('--capacity-wh', type=float, required=True)
    args = parser.parse_args()
    print(json.dumps(analyze([json.loads(line) for line in args.battery.read_text().splitlines()],
                            json.loads(args.windows.read_text()), args.capacity_wh), indent=2))
