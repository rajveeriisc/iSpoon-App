import Flutter
import FirebaseMessaging
import UIKit
import UserNotifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Set notification delegate so foreground notifications display correctly
    UNUserNotificationCenter.current().delegate = self

    // Register workmanager background task identifiers with BGTaskScheduler.
    // This MUST be called before application(_:didFinishLaunchingWithOptions:) returns.
    // Each identifier listed here must also appear in Info.plist BGTaskSchedulerPermittedIdentifiers.
    WorkmanagerPlugin.registerPeriodicTask(withIdentifier: "daily-sync-11pm", frequency: nil)
    WorkmanagerPlugin.registerPeriodicTask(withIdentifier: "test-sync-15min", frequency: nil)

    // CoreBluetooth state restoration is ON: main.dart calls
    // FlutterBluePlus.setOptions(restoreState: true) before any other BLE call,
    // which gives flutter_blue_plus's CBCentralManager a restore identifier.
    // When iOS relaunches the app in the background for a spoon connection,
    // the plugin re-adopts the restored peripherals. Do not create a second
    // CBCentralManager here — it would not own the plugin's connections and
    // would not restore them. (A force-quit from the app switcher still turns
    // background relaunch off until the user opens the app; that is iOS.)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    // Firebase method swizzling is disabled in Info.plist, so APNs tokens must
    // be forwarded explicitly or FCM registration never completes on iOS.
    Messaging.messaging().apnsToken = deviceToken
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
