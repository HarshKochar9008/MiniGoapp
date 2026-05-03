import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "whoosh/native_share"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: channelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak controller] call, result in
        guard call.method == "shareText" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard
          let args = call.arguments as? [String: Any],
          let text = args["text"] as? String,
          !text.isEmpty
        else {
          result(
            FlutterError(code: "invalid_args", message: "Missing text", details: nil)
          )
          return
        }
        let subject = args["subject"] as? String
        let activityController = UIActivityViewController(
          activityItems: [text],
          applicationActivities: nil
        )
        if let subject {
          activityController.setValue(subject, forKey: "subject")
        }
        controller?.present(activityController, animated: true)
        result(nil)
      }
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
