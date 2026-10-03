import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    PrivateGalleryLaunchInvite.register(with: engineBridge)
  }
}

/// Debug-only transport that lets a paired session (desktop URL + bearer token)
/// be injected at launch, mirroring Android's `private_gallery/launch_invite`
/// channel. It exists so an automated harness can point the app at a real
/// `galleryd`. Release builds compile the whole thing out, so a shipped app can
/// never be silently re-pointed at an arbitrary backend.
///
/// The values are read from the process arguments (`simctl launch ... <args>`)
/// or the environment; arguments win so a harness can override a stale variable.
enum PrivateGalleryLaunchInvite {
  private static let channelName = "private_gallery/launch_invite"

  static func register(with bridge: FlutterImplicitEngineBridge) {
    #if DEBUG
      let registrar = bridge.pluginRegistry.registrar(forPlugin: "PrivateGalleryLaunchInvite")
      let channel = FlutterMethodChannel(
        name: channelName,
        binaryMessenger: registrar.messenger()
      )
      var pending = inviteFromLaunchContext()
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "consumeInitialInvite":
          let invite = pending
          pending = nil
          result(invite)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    #else
      _ = bridge
    #endif
  }

  #if DEBUG
    private static func inviteFromLaunchContext() -> [String: Any]? {
      let arguments = ProcessInfo.processInfo.arguments
      let environment = ProcessInfo.processInfo.environment
      let desktopUrl = firstValue(
        arguments: arguments, environment: environment,
        flag: "--private-gallery-desktop-url", variable: "PRIVATE_GALLERY_DESKTOP_URL")
      let bearerToken = firstValue(
        arguments: arguments, environment: environment,
        flag: "--private-gallery-bearer-token", variable: "PRIVATE_GALLERY_BEARER_TOKEN")
      let deviceName = firstValue(
        arguments: arguments, environment: environment,
        flag: "--private-gallery-device-name", variable: "PRIVATE_GALLERY_DEVICE_NAME")
      guard let desktopUrl, !desktopUrl.isEmpty,
        let bearerToken, !bearerToken.isEmpty
      else {
        return nil
      }
      var invite: [String: Any] = ["desktopUrl": desktopUrl, "bearerToken": bearerToken]
      if let deviceName, !deviceName.isEmpty {
        invite["deviceName"] = deviceName
      }
      return invite
    }

    private static func firstValue(
      arguments: [String], environment: [String: String], flag: String, variable: String
    ) -> String? {
      if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
        return arguments[index + 1]
      }
      if let value = environment[variable], !value.isEmpty {
        return value
      }
      return nil
    }
  #endif
}
