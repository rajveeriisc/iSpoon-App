import pandas as pd
import numpy as np
import glob
import os
from sklearn.model_selection import train_test_split
from sklearn.tree import DecisionTreeClassifier, export_text
from sklearn.metrics import classification_report, confusion_matrix

def load_data(data_dir):
    """Loads all CSV files from the specified directory."""
    all_files = glob.glob(os.path.join(data_dir, "*.csv"))
    if not all_files:
        print(f"No CSV files found in {data_dir}. Please add the 7 datasets.")
        return None
    
    df_list = []
    for filename in all_files:
        try:
            df = pd.read_csv(filename)
            df['source_file'] = os.path.basename(filename)
            df_list.append(df)
        except Exception as e:
            print(f"Error reading {filename}: {e}")
            
    if not df_list:
        return None
        
    return pd.concat(df_list, axis=0, ignore_index=True)

def extract_features(df):
    """
    Groups continuous frames of motion and extracts features for the classifier.
    A 'window' is defined as a contiguous block where frame_state is 'moving', 'steady', or 'returning'.
    """
    print("Extracting features from windows...")
    
    # Create a unique window ID for contiguous active states
    df['is_active'] = df['frame_state'].isin(['moving', 'steady', 'returning']).astype(int)
    
    # Identify where active state changes
    df['state_change'] = df['is_active'].diff().ne(0).astype(int)
    
    # Group ID for windows (each block gets a unique ID)
    df['window_id'] = (df['state_change'] * df['is_active']).cumsum()
    
    # Filter only active windows
    active_windows = df[df['is_active'] == 1]
    
    if active_windows.empty:
        print("No active motion windows found.")
        return None
        
    features = []
    
    for window_id, group in active_windows.groupby('window_id'):
        if len(group) < 10:  # Skip tiny glitches (< 100ms)
            continue
            
        # Ground truth: Did the user tap 'bite' during this window (or very close to it)?
        # 1 = Bite, 0 = No Bite (e.g., reaching for food but not eating, fast movement, etc.)
        is_true_bite = 1 if group['user_bite_mark'].max() == 1 else 0
        
        # Current system prediction
        system_detected = 1 if group['system_bite_detected'].max() == 1 else 0
        
        # Calculate features for this window
        duration_ms = group['timestamp_ms'].max() - group['timestamp_ms'].min()
        max_accel = group['linearAccel'].max()
        mean_accel = group['linearAccel'].mean()
        max_gyro = group['gyroMag'].max()
        mean_gyro = group['gyroMag'].mean()
        accel_variance = group['linearAccel'].var()
        
        # Add to feature set
        features.append({
            'window_id': window_id,
            'duration_ms': duration_ms,
            'max_accel': max_accel,
            'mean_accel': mean_accel,
            'max_gyro': max_gyro,
            'mean_gyro': mean_gyro,
            'accel_variance': accel_variance if not np.isnan(accel_variance) else 0,
            'is_true_bite': is_true_bite,
            'system_detected': system_detected
        })
        
    return pd.DataFrame(features)

def train_and_evaluate(feature_df):
    """Trains a Decision Tree on the extracted features and compares with the baseline."""
    
    print(f"\nTotal windows analyzed: {len(feature_df)}")
    print(f"Total True Bites (Ground Truth): {feature_df['is_true_bite'].sum()}")
    
    # Baseline accuracy (Current hardcoded thresholds)
    print("\n--- BASELINE (Current Hardcoded System) ---")
    print(confusion_matrix(feature_df['is_true_bite'], feature_df['system_detected']))
    print(classification_report(feature_df['is_true_bite'], feature_df['system_detected']))
    
    # Prepare data for ML model
    X = feature_df[['duration_ms', 'max_accel', 'mean_accel', 'max_gyro', 'mean_gyro', 'accel_variance']]
    y = feature_df['is_true_bite']
    
    # Try multiple splits if data is small, but for now simple split
    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.3, random_state=42)
    
    # Train a shallow decision tree (so it can be easily ported to Dart)
    clf = DecisionTreeClassifier(max_depth=4, min_samples_leaf=3, random_state=42, class_weight='balanced')
    clf.fit(X_train, y_train)
    
    # Evaluate
    y_pred = clf.predict(X_test)
    
    print("\n--- NEW OPTIMIZED MODEL (Decision Tree) ---")
    print(confusion_matrix(y_test, y_pred))
    print(classification_report(y_test, y_pred))
    
    print("\n--- Dart Implementation Logic ---")
    tree_rules = export_text(clf, feature_names=list(X.columns))
    print(tree_rules)
    print("\nTranslate the above tree into if/else statements in AiTremorService._AiBiteFrameDetector")

if __name__ == "__main__":
    dataset_dir = "datasets"  # Create this folder and put the 7 CSVs here
    
    if not os.path.exists(dataset_dir):
        os.makedirs(dataset_dir)
        print(f"Created directory '{dataset_dir}'. Please place the exported AI Lab CSV files inside and run this script again.")
    else:
        df = load_data(dataset_dir)
        if df is not None:
            features = extract_features(df)
            if features is not None:
                train_and_evaluate(features)
