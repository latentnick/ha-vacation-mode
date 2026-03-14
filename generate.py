import json

import numpy as np
import pandas as pd


def _sigmoid(x):
    return 1 / (1 + np.exp(-x))


def _compute_hourly_priors(features_df, entities):
    """Compute historical on-rate for each light by (hour, is_weekend)."""
    df = features_df[entities].copy()
    df['hour'] = features_df.index.hour
    df['is_weekend'] = features_df.index.dayofweek.isin([5, 6]).astype(int)
    return df.groupby(['hour', 'is_weekend'])[entities].mean()


def generate_vacation_schedule(model, start_date, num_days,
                               sequence_length, input_features, entities,
                               features_df, temperature=0.5,
                               prior_weight=0.3):
    """
    Generate a vacation schedule by predicting light states directly.

    At each 15-min step the model outputs P(light is on) for each light.
    The prediction is blended with an hourly prior from historical data to
    prevent the autoregressive loop from getting stuck in one state.
    We then sample from the blended probability to get the new state.

    The generation is seeded with the last portion of real historical data so
    that time-in-state counters and lag features start from meaningful values.

    Args:
        model: Trained Keras model (predicts state probabilities)
        start_date: Starting datetime for the schedule (timezone-aware)
        num_days: Number of days to generate
        sequence_length: Length of input sequences for the model
        input_features: Ordered list of input feature names
        entities: List of light entity names (used as output columns)
        features_df: Historical feature DataFrame (for seeding)
        temperature: Controls randomness. <1 = more deterministic, >1 = more random
        prior_weight: Weight for hourly prior (0-1). Higher values rely more on
                      historical patterns; lower values rely more on the model.

    Returns:
        DataFrame with columns=entities and index=time, containing 0/1 states.
    """
    time_index = pd.date_range(
        start=start_date,
        periods=num_days * 96,
        freq='15min'
    )

    hourly_priors = _compute_hourly_priors(features_df, entities)

    # Seed the feature buffer with the last max(sequence_length, 7*96) historical rows
    # so lag features (24h ago, 7d ago) have real data to look back to.
    lookback = max(sequence_length, 96 * 7)
    seed_features = features_df[input_features].iloc[-lookback:].values.copy()

    # Seed current light states and time-in-state counters from end of history
    hist_states = features_df[entities].values
    current_state = hist_states[-1].astype(int).copy()

    tis_counters = np.ones(len(entities), dtype=int)
    for j in range(len(entities)):
        last_val = hist_states[-1, j]
        for k in range(2, min(len(hist_states), 96 * 24) + 1):
            if hist_states[-k, j] == last_val:
                tis_counters[j] += 1
            else:
                break

    # state_history holds all states (seed + generated) for lag lookups
    state_history = list(hist_states[-lookback:])

    # feature_buffer holds all feature rows (seed + generated) for sequence building
    feature_buffer = list(seed_features)

    generated_states = []

    for step_i, t in enumerate(time_index):
        # Build input sequence from the last sequence_length feature rows
        seq = np.array(feature_buffer[-sequence_length:])
        X_input = seq.reshape(1, sequence_length, len(input_features))

        pred_proba = model.predict(X_input, verbose=0)[0]

        # Temperature scaling via logit space: <1 = more deterministic, >1 = more random
        pred_proba = np.clip(pred_proba, 0.001, 0.999)
        logits = np.log(pred_proba / (1 - pred_proba))
        scaled_proba = _sigmoid(logits / temperature)

        # Blend with hourly prior to prevent autoregressive state lock-in.
        # The model tends to predict "stay in current state" which causes
        # lights to get stuck off during generation.
        hour = t.hour
        is_wknd = 1 if t.dayofweek >= 5 else 0
        prior_key = (hour, is_wknd)
        if prior_key in hourly_priors.index:
            prior = hourly_priors.loc[prior_key].values
        else:
            prior = scaled_proba  # fallback: no blending
        blended_proba = (1 - prior_weight) * scaled_proba + prior_weight * prior

        # Sample states directly from blended probabilities
        new_state = (np.random.random(len(blended_proba)) < blended_proba).astype(int)

        # Update time-in-state counters
        for j in range(len(entities)):
            if new_state[j] != current_state[j]:
                tis_counters[j] = 1
            else:
                tis_counters[j] += 1
        current_state = new_state
        tis_normalized = np.clip(tis_counters, 1, 96) / 96

        # Append new state to history for lag lookups
        state_history.append(current_state.copy())

        # Build feature row for this step (fed into model on the next iteration)
        new_features = np.zeros(len(input_features))

        for j, entity in enumerate(entities):
            new_features[input_features.index(entity)] = current_state[j]

        new_features[input_features.index('hour_sin')] = np.sin(2 * np.pi * t.hour / 24)
        new_features[input_features.index('hour_cos')] = np.cos(2 * np.pi * t.hour / 24)
        new_features[input_features.index('day_sin')] = np.sin(2 * np.pi * t.dayofweek / 7)
        new_features[input_features.index('day_cos')] = np.cos(2 * np.pi * t.dayofweek / 7)
        new_features[input_features.index('is_weekend')] = 1 if t.dayofweek >= 5 else 0
        new_features[input_features.index('total_lights_on')] = current_state.sum()

        for j, entity in enumerate(entities):
            new_features[input_features.index(f'{entity}_time_in_state')] = tis_normalized[j]

        # Lag features: look back 96 steps (24h) and 672 steps (7d) in state_history.
        # state_history[-1] is the state we just appended (current step),
        # so state_history[-97] is 96 steps before current = 24h ago.
        hist_len = len(state_history)
        for j, entity in enumerate(entities):
            lag_24h = state_history[-97][j] if hist_len > 96 else 0
            lag_7d = state_history[-673][j] if hist_len > 672 else 0
            new_features[input_features.index(f'{entity}_24h_ago')] = lag_24h
            new_features[input_features.index(f'{entity}_7d_ago')] = lag_7d

        feature_buffer.append(new_features)
        generated_states.append(current_state.copy())

    return pd.DataFrame(generated_states, index=time_index, columns=entities)


def create_readable_schedule(schedule_df, entity_name):
    """Convert binary schedule to readable on/off time periods."""
    events = []
    current_state = None
    state_start = None

    for time, state in schedule_df[entity_name].items():
        if state != current_state:
            if current_state is not None:
                events.append({
                    'start': state_start,
                    'end': time,
                    'state': 'ON' if current_state == 1 else 'OFF',
                    'duration': (time - state_start).total_seconds() / 3600
                })
            current_state = state
            state_start = time

    if current_state is not None:
        events.append({
            'start': state_start,
            'end': schedule_df.index[-1],
            'state': 'ON' if current_state == 1 else 'OFF',
            'duration': (schedule_df.index[-1] - state_start).total_seconds() / 3600
        })

    return pd.DataFrame(events)


def export_schedule_events(vacation_schedule, entities, entity_map_path, output_path):
    """
    Export schedule as on/off events JSON for vacation_daemon.py.

    Returns:
        list of event dicts (also written to output_path)
    """
    with open(entity_map_path) as f:
        entity_map = json.load(f)

    all_events = []
    for entity in entities:
        readable = create_readable_schedule(vacation_schedule, entity)
        ha_entity = entity_map[entity]
        for _, period in readable[readable['state'] == 'ON'].iterrows():
            all_events.append({
                'time': period['start'].isoformat(),
                'entity_id': ha_entity,
                'action': 'turn_on'
            })
            all_events.append({
                'time': period['end'].isoformat(),
                'entity_id': ha_entity,
                'action': 'turn_off'
            })

    all_events.sort(key=lambda e: e['time'])

    with open(output_path, 'w') as f:
        json.dump(all_events, f, indent=2)

    return all_events
