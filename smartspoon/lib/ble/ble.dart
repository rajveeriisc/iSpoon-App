/// Public BLE layer. Screens and domain services talk to [SpoonRuntime].
library;

export 'ble_platform_bridge.dart' show BleAdapterState, BleSighting;
export 'connection_coordinator.dart'
    show ClaimOutcome, ClaimResult, SwitchOutcome;
export 'models/runtime_models.dart';
export 'models/spoon_models.dart' show SpoonState, DisconnectReason;
export 'spoon_runtime.dart';
