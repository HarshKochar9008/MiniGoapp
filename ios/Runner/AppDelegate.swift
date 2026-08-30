import Flutter
import QuickLook
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "minigo/native_share"
  private let saveChannelName = "minigo/native_save"

  /// QLPreviewController holds its data source weakly, so this is what keeps
  /// the previewed item alive for as long as the sheet is up.
  private var preview: FilePreview?

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

      // Received files are saved by the `gal` plugin (Photos) or into the app's
      // documents folder, and neither hands back something a URL can open — so
      // Open previews the file itself rather than launching another app.
      let saveChannel = FlutterMethodChannel(
        name: saveChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      saveChannel.setMethodCallHandler { [weak self, weak controller] call, result in
        guard call.method == "openFile" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard
          let args = call.arguments as? [String: Any],
          let path = args["target"] as? String,
          FileManager.default.fileExists(atPath: path)
        else {
          result(
            FlutterError(
              code: "not_found",
              message: "This file is no longer on the device",
              details: nil
            )
          )
          return
        }
        let url = URL(fileURLWithPath: path)
        guard QLPreviewController.canPreview(url as NSURL) else {
          result(
            FlutterError(
              code: "no_viewer",
              message: "iOS has no preview for this kind of file",
              details: nil
            )
          )
          return
        }
        let item = FilePreview(url: url)
        self?.preview = item
        let quickLook = QLPreviewController()
        quickLook.dataSource = item
        controller?.present(quickLook, animated: true)
        result(nil)
      }
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// A Quick Look sheet showing one file — the one that just arrived.
private final class FilePreview: NSObject, QLPreviewControllerDataSource {
  private let url: NSURL

  init(url: URL) {
    self.url = url as NSURL
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

  func previewController(
    _ controller: QLPreviewController,
    previewItemAt index: Int
  ) -> QLPreviewItem {
    url
  }
}
