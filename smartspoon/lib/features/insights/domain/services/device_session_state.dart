// device_session_state.dart — per-device mutable meal-session state holder.
//
// A plain mutable container (one per connected spoon, keyed by deviceId inside
// UnifiedDataService) that tracks everything about the current eating session:
// whether a session is active, its start time and meal UUID, the inactivity
// timer, bite timestamps + smoothed pace, hardware/background bite counters and
// baselines, cached background telemetry (bites/accel/battery/temp), and heater
// start time. Keeping this per-device prevents two spoons from clobbering each
// other's session data.
import 'dart:async';

class DeviceSessionState {
  final String deviceId;
  
  bool isSessionActive = false;
  DateTime? sessionStartTime;
  String? currentMealUuid;
  Timer? sessionInactivityTimer;
  
  List<DateTime> biteTimestamps = [];
  double smoothedSpeedBpm = 0.0;
  
  bool hwBiteInitialized = false;
  int uncommittedBites = 0;
  int lastHardwareBiteCount = 0;
  
  // Background BLE data
  int bgBiteCount = 0;
  double bgAvgAccel = 0;
  int bgBattery = 0;
  double bgTemperature = 0;
  DateTime? bgLastUpdate;
  
  // Meal Tracking
  int startBiteCount = 0;
  int endBiteCount = 0;
  
  // Heater
  DateTime? heaterStartTime;

  DeviceSessionState(this.deviceId);
}
