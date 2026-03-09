import numpy as np
import pandas as pd


def compute_time_in_state(series):
    """Count consecutive steps each value has been unchanged."""
    counts = []
    count = 0
    prev = None
    for val in series:
        if val != prev:
            count = 1
        else:
            count += 1
        counts.append(count)
        prev = val
    return counts


def build_features(all_lights, entities):
    """
    Build all features from the raw light state DataFrame.

    Returns:
        features_df: DataFrame with all input and target columns
        input_features: ordered list of input column names
        target_features: ordered list of target column names (light states)
    """
    features_df = all_lights.copy()

    # Temporal features
    features_df['hour'] = features_df.index.hour
    features_df['day_of_week'] = features_df.index.dayofweek
    features_df['is_weekend'] = features_df['day_of_week'].isin([5, 6]).astype(int)

    # Cyclical encoding (so 23:00 is close to 00:00, Sunday close to Monday)
    features_df['hour_sin'] = np.sin(2 * np.pi * features_df['hour'] / 24)
    features_df['hour_cos'] = np.cos(2 * np.pi * features_df['hour'] / 24)
    features_df['day_sin'] = np.sin(2 * np.pi * features_df['day_of_week'] / 7)
    features_df['day_cos'] = np.cos(2 * np.pi * features_df['day_of_week'] / 7)

    # Context
    features_df['total_lights_on'] = features_df[entities].sum(axis=1)

    # Time in current state (normalized, capped at 96 steps = 24 hours)
    for entity in entities:
        raw_counts = compute_time_in_state(features_df[entity].tolist())
        features_df[f'{entity}_time_in_state'] = np.clip(raw_counts, 1, 96) / 96

    # Lag features: same time 24h ago and 7 days ago
    for entity in entities:
        features_df[f'{entity}_24h_ago'] = features_df[entity].shift(96).fillna(0).astype(int)
        features_df[f'{entity}_7d_ago'] = features_df[entity].shift(96 * 7).fillna(0).astype(int)

    # Define feature groups
    state_features = list(entities)
    temporal_features = ['hour_sin', 'hour_cos', 'day_sin', 'day_cos', 'is_weekend']
    context_features = ['total_lights_on']
    time_in_state_features = [f'{e}_time_in_state' for e in entities]
    lag_features = [f'{e}_24h_ago' for e in entities] + [f'{e}_7d_ago' for e in entities]

    input_features = (state_features + temporal_features + context_features
                      + time_in_state_features + lag_features)
    target_features = list(entities)  # predict light states directly

    return features_df, input_features, target_features


def create_sequences(data, input_cols, target_cols, sequence_length, prediction_horizon=1):
    """
    Create sliding-window sequences for LSTM training.

    Returns:
        X: Input sequences (samples, sequence_length, features)
        y: Target values (samples, num_targets)
    """
    X, y = [], []

    for i in range(len(data) - sequence_length - prediction_horizon + 1):
        X.append(data[input_cols].iloc[i:i + sequence_length].values)
        y.append(data[target_cols].iloc[i + sequence_length + prediction_horizon - 1].values)

    return np.array(X), np.array(y)
