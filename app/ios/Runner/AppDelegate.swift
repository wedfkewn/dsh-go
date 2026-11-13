import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshPetLiveActivity") {
      PetLiveActivityPlugin.register(with: registrar)
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshNotify") {
      NotifyPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshShellBox") {
      ShellBoxPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshNativeNodeScaffold") {
      NativeNodeScaffold.register(with: registrar)
    }
  }
}

// This distinct channel is intentionally not selected until the native
// NodeMobile runtime has been embedded, signed and verified on device.
private enum NativeNodeScaffold {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dsh/native_node",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "status":
        result([
          "phase": "unimplemented",
          "error": [
            "code": "native_node_unavailable",
            "message": "The native NodeMobile runtime has not been linked."
          ]
        ])
      case "start", "stop", "restart":
        result(FlutterError(
          code: "native_node_unavailable",
          message: "The native NodeMobile runtime has not been linked.",
          details: nil
        ))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
