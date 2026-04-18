"""
Empirical-day (and -block) resampling.

For each block of each day in the vacation window, sample a real historical
day matching day-of-week (weighted toward seasonally close donors), then replay
that donor's events that fall within the block on the target day with small
jitter applied to each timestamp. With --blocks 1 this is whole-day replay;
larger values stitch together different donors per time-of-day window for more
diversity (e.g. morning from one donor, evening from another).

Usage:
    uv run generate_resample.py 2026-04-01 2026-04-08
    uv run generate_resample.py 2026-04-01 2026-04-08 --blocks 4
"""
import argparse
import json
import os
import random
from datetime import timedelta

import pandas as pd


def load_events(csv_path: str):
    """Load raw switch events. Deduplicate consecutive same-state rows per entity."""
    df = pd.read_csv(csv_path)
    df['time'] = pd.to_datetime(df['time'], utc=True).dt.tz_convert('US/Pacific')
    df['state'] = df['state.value'].astype(int)
    df = df.sort_values(['entity_id', 'time']).reset_index(drop=True)

    df['prev'] = df.groupby('entity_id')['state'].shift(1)
    transitions = df[df['state'] != df['prev']].copy()
    transitions['action'] = transitions['state'].map({1: 'turn_on', 0: 'turn_off'})
    transitions['date'] = transitions['time'].dt.normalize()

    entities = sorted(df['entity_id'].unique())
    return transitions[['time', 'date', 'entity_id', 'state', 'action']], entities


def state_at_time(transitions: pd.DataFrame, t: pd.Timestamp, entities: list[str]) -> dict[str, int]:
    """Determine each entity's state immediately before time `t`."""
    before = transitions[transitions['time'] < t]
    state = {e: 0 for e in entities}
    if before.empty:
        return state
    last = before.groupby('entity_id')['state'].last()
    for e, s in last.items():
        state[e] = int(s)
    return state


def candidate_dates(transitions: pd.DataFrame) -> list[pd.Timestamp]:
    """All historical dates with at least one full day of coverage.

    Drops the first and last calendar dates as they are usually partial.
    """
    all_dates = sorted(transitions['date'].unique())
    if len(all_dates) <= 2:
        return all_dates
    return all_dates[1:-1]


def pick_donor(target: pd.Timestamp, candidates: list[pd.Timestamp], rng: random.Random) -> pd.Timestamp:
    """Pick a historical donor date matching target's day-of-week, weighted by
    seasonal proximity (smaller circular day-of-year distance = higher weight)."""
    same_dow = [c for c in candidates if c.dayofweek == target.dayofweek]
    pool = same_dow if same_dow else candidates

    def circ_doy_distance(c: pd.Timestamp) -> int:
        d = abs(c.dayofyear - target.dayofyear)
        return min(d, 365 - d)

    weights = [1.0 / (1 + circ_doy_distance(c)) for c in pool]
    return rng.choices(pool, weights=weights, k=1)[0]


def replay_block(
    target_block_start: pd.Timestamp,
    target_block_end: pd.Timestamp,
    donor_block_start: pd.Timestamp,
    donor_block_end: pd.Timestamp,
    transitions: pd.DataFrame,
    entities: list[str],
    sim_state: dict[str, int],
    jitter_minutes: int,
    rng: random.Random,
) -> list[dict]:
    """Replay the donor's events within [donor_block_start, donor_block_end)
    onto [target_block_start, target_block_end). Aligns sim_state to the
    donor's state at the block start, then emits jittered events. Mutates
    sim_state.
    """
    donor_state = state_at_time(transitions, donor_block_start, entities)
    out = []

    # Align simulated state to donor's state at the block boundary.
    for e in entities:
        if sim_state[e] != donor_state[e]:
            action = 'turn_on' if donor_state[e] == 1 else 'turn_off'
            out.append({'time': target_block_start, 'entity_id': e, 'action': action})
            sim_state[e] = donor_state[e]

    # Replay donor events within the block, jittered.
    donor_events = transitions[
        (transitions['time'] >= donor_block_start) &
        (transitions['time'] < donor_block_end)
    ].sort_values('time')

    for _, ev in donor_events.iterrows():
        offset = ev['time'] - donor_block_start
        jitter = pd.Timedelta(minutes=rng.uniform(-jitter_minutes, jitter_minutes))
        new_time = target_block_start + offset + jitter
        # Clamp inside the block so jitter doesn't leak across boundaries.
        if new_time < target_block_start:
            new_time = target_block_start
        elif new_time >= target_block_end:
            new_time = target_block_end - pd.Timedelta(seconds=1)

        e = ev['entity_id']
        new_state = int(ev['state'])
        if sim_state[e] == new_state:
            continue
        sim_state[e] = new_state
        out.append({'time': new_time, 'entity_id': e, 'action': ev['action']})

    return out


def block_offsets(n_blocks: int) -> list[pd.Timedelta]:
    """Boundary offsets from midnight for `n_blocks` equal-width blocks
    over a 24-hour day. Returns n_blocks+1 offsets (start of each + end-of-day).
    """
    if n_blocks < 1:
        raise ValueError("n_blocks must be >= 1")
    width_minutes = 24 * 60 // n_blocks
    return [pd.Timedelta(minutes=i * width_minutes) for i in range(n_blocks)] + [pd.Timedelta(days=1)]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('vacation_start', help='YYYY-MM-DD (Pacific, inclusive)')
    ap.add_argument('vacation_end', help='YYYY-MM-DD (Pacific, exclusive)')
    ap.add_argument('--data', default='out/data.csv')
    ap.add_argument('--entity-map', default='out/entity_map.json')
    ap.add_argument('--output', default='out/schedule_events.json')
    ap.add_argument('--jitter-minutes', type=int, default=10)
    ap.add_argument('--blocks', type=int, default=2,
                    help='Number of equal time blocks per day; each block draws an '
                         'independent donor. 1 = whole-day replay; 2 (default) splits '
                         'morning/evening, which empirically beats both 1 and finer splits.')
    ap.add_argument('--seed', type=int, default=None)
    args = ap.parse_args()

    rng = random.Random(args.seed)

    transitions, entities = load_events(args.data)
    candidates = candidate_dates(transitions)
    if not candidates:
        raise SystemExit("No historical dates available — fetch more data first.")

    start = pd.Timestamp(args.vacation_start, tz='US/Pacific').normalize()
    end = pd.Timestamp(args.vacation_end, tz='US/Pacific').normalize()
    if end <= start:
        raise SystemExit(f"vacation_end ({end.date()}) must be after vacation_start ({start.date()}).")
    target_dates = list(pd.date_range(start, end - pd.Timedelta(days=1), freq='D', tz='US/Pacific'))

    offsets = block_offsets(args.blocks)
    sim_state = {e: 0 for e in entities}
    raw_events: list[dict] = []
    for target in target_dates:
        for b in range(args.blocks):
            donor = pick_donor(target, candidates, rng)
            raw_events.extend(replay_block(
                target_block_start=target + offsets[b],
                target_block_end=target + offsets[b + 1],
                donor_block_start=donor + offsets[b],
                donor_block_end=donor + offsets[b + 1],
                transitions=transitions,
                entities=entities,
                sim_state=sim_state,
                jitter_minutes=args.jitter_minutes,
                rng=rng,
            ))

    # Make sure the vacation ends with all lights off.
    end_marker = end - pd.Timedelta(seconds=1)
    for e in entities:
        if sim_state[e] == 1:
            raw_events.append({'time': end_marker, 'entity_id': e, 'action': 'turn_off'})
            sim_state[e] = 0

    raw_events.sort(key=lambda x: x['time'])

    # Jitter can reorder a day's events; drop any event that doesn't change state
    # in the final sorted order. (Done as a separate pass because per-day dedup
    # uses pre-sort state.)
    final_state = {e: 0 for e in entities}
    deduped: list[dict] = []
    for ev in raw_events:
        new = 1 if ev['action'] == 'turn_on' else 0
        if final_state[ev['entity_id']] == new:
            continue
        final_state[ev['entity_id']] = new
        deduped.append(ev)
    raw_events = deduped

    with open(args.entity_map) as f:
        entity_map = json.load(f)

    json_events = [
        {
            'time': ev['time'].isoformat(),
            'entity_id': entity_map[ev['entity_id']],
            'action': ev['action'],
        }
        for ev in raw_events
    ]

    os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)
    with open(args.output, 'w') as f:
        json.dump(json_events, f, indent=2)

    print(f"Wrote {len(json_events)} events to {args.output}")
    print(f"Vacation window: {start.date()} → {end.date()} ({len(target_dates)} days, "
          f"{args.blocks} blocks/day)")
    print(f"Donor pool: {len(candidates)} historical days, {len(entities)} entities")


if __name__ == '__main__':
    main()
