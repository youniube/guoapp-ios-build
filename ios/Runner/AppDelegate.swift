import Flutter
import UIKit
import DuanjuCore
import CFNetwork
import AVFAudio
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, FlutterStreamHandler {
  private var brightnessScreen: UIScreen?
  private var originalBrightness: CGFloat?
  private var brightnessBackgroundObserver: NSObjectProtocol?
  private var deviceRegistrar: FlutterPluginRegistrar?
  private var mediaVolumeView: MPVolumeView?
  private var mediaVolumeObservation: NSKeyValueObservation?
  private var mediaVolumeSink: FlutterEventSink?

  private func mediaVolumeSlider() -> UISlider? {
    guard let parent = deviceRegistrar?.viewController?.view else { return nil }
    let volumeView: MPVolumeView
    if let existing = mediaVolumeView {
      volumeView = existing
    } else {
      volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 200, height: 40))
      volumeView.showsRouteButton = false
      volumeView.isUserInteractionEnabled = false
      mediaVolumeView = volumeView
    }
    if volumeView.superview !== parent {
      parent.addSubview(volumeView)
    }
    volumeView.layoutIfNeeded()
    return volumeView.subviews.compactMap { $0 as? UISlider }.first
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    mediaVolumeSink = events
    _ = mediaVolumeSlider()
    mediaVolumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, _ in
      let volume = Double(session.outputVolume)
      DispatchQueue.main.async {
        self?.mediaVolumeSink?(volume)
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    mediaVolumeObservation?.invalidate()
    mediaVolumeObservation = nil
    mediaVolumeSink = nil
    mediaVolumeView?.removeFromSuperview()
    mediaVolumeView = nil
    return nil
  }

  private func resetPlaybackBrightness() {
    if let screen = brightnessScreen, let brightness = originalBrightness {
      screen.brightness = brightness
    }
    brightnessScreen = nil
    originalBrightness = nil
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    resetPlaybackBrightness()
    super.applicationDidEnterBackground(application)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ZgjEnsureCoreLinked()
    brightnessBackgroundObserver = NotificationCenter.default.addObserver(
      forName: UIScene.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.resetPlaybackBrightness()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceSettings") {
      deviceRegistrar = registrar
      let volumeEvents = FlutterEventChannel(name: "duanju/media_volume", binaryMessenger: registrar.messenger())
      volumeEvents.setStreamHandler(self)
      let channel = FlutterMethodChannel(name: "duanju/device", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        let screen = UIScreen.main
        switch call.method {
        case "getMediaVolume":
          _ = self?.mediaVolumeSlider()
          result(Double(AVAudioSession.sharedInstance().outputVolume))
          return
        case "setMediaVolume":
          guard let self,
                let arguments = call.arguments as? [String: Any],
                let volume = arguments["volume"] as? NSNumber,
                volume.doubleValue.isFinite else {
            result(FlutterError(code: "invalid_volume", message: "音量参数无效", details: nil))
            return
          }
          guard UIApplication.shared.applicationState == .active,
                let slider = self.mediaVolumeSlider(), slider.isEnabled else {
            result(FlutterError(code: "volume_unavailable", message: "当前音频输出不支持系统音量调节", details: nil))
            return
          }
          slider.setValue(Float(min(1.0, max(0.0, volume.doubleValue))), animated: false)
          slider.sendActions(for: .valueChanged)
          result(nil)
          return
        case "pythonRuntime":
          let home = Bundle.main.bundleURL.appendingPathComponent("python").path
          let library = Bundle.main.bundleURL.appendingPathComponent("Frameworks/Python.framework/Python").path
          result(["home": home, "library": library, "search": [home, home + "/lib/python3.14", home + "/lib/python3.14/lib-dynload", home + "/lib/python3.14/site-packages"]])
          return
        case "deviceInfo":
          let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
          let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
          result(["television": false, "version": build.isEmpty ? version : "\(version)+\(build)"])
          return
        case "getBrightness":
          result(Double(screen.brightness))
          return
        case "setBrightness":
          guard let self,
                let arguments = call.arguments as? [String: Any],
                let brightness = arguments["brightness"] as? NSNumber else {
            result(FlutterError(code: "invalid_brightness", message: "亮度参数无效", details: nil))
            return
          }
          guard UIApplication.shared.applicationState == .active else {
            result(nil)
            return
          }
          if self.originalBrightness == nil {
            self.originalBrightness = screen.brightness
            self.brightnessScreen = screen
          }
          screen.brightness = CGFloat(min(1.0, max(0.01, brightness.doubleValue)))
          result(nil)
          return
        case "resetBrightness":
          self?.resetPlaybackBrightness()
          result(nil)
          return
        default:
          break
        }
        guard call.method == "systemProxy" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        func address(_ prefix: String) -> String {
          guard (settings["\(prefix)Enable"] as? NSNumber)?.boolValue == true,
                let host = settings["\(prefix)Proxy"] as? String,
                let port = settings["\(prefix)Port"] as? NSNumber,
                !host.isEmpty, port.intValue > 0 else { return "" }
          let name = host.contains(":") ? "[\(host)]" : host
          return "http://\(name):\(port.intValue)"
        }
        let http = address("HTTP")
        let https = address("HTTPS")
        result(["http": http, "https": https.isEmpty ? http : https,
                "bypass": settings["ExceptionsList"] as? [String] ?? [],
                "pac": (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true])
      }
    }
  }
}
