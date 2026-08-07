import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private static let serialBridgeChannel = "dev.solsynth.maidKit/serial_bridge"

  /// The running serial-bridge helper. The app is not sandboxed, so the
  /// helper runs as a plain child process and can open /dev/cu.* device
  /// nodes directly; no LaunchAgent or approval flow is involved.
  private var serialBridgeProcess: Process?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    serialBridgeProcess?.terminate()
    super.applicationWillTerminate(notification)
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else {
      return
    }
    let channel = FlutterMethodChannel(
      name: Self.serialBridgeChannel,
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "ensureRegistered":
        self?.ensureSerialBridgeRegistered(result: result)
      case "openLoginItemsSettings":
        // No approval flow: the helper is spawned directly by the app.
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Ensures the bundled serial-bridge helper is running and reports its
  /// status. The helper is respawned if it exits after a healthy run, so a
  /// crashed helper recovers without an app restart.
  private func ensureSerialBridgeRegistered(result: @escaping FlutterResult) {
    guard let helper = Bundle.main.resourceURL?.appendingPathComponent("serial-bridge"),
      FileManager.default.isExecutableFile(atPath: helper.path)
    else {
      result("notFound")
      return
    }
    if let process = serialBridgeProcess, process.isRunning {
      result("enabled")
      return
    }
    let process = Process()
    process.executableURL = helper
    process.arguments = [Bundle.main.bundleIdentifier ?? "dev.solsynth.maidKit"]
    let launchTime = Date()
    process.terminationHandler = { [weak self] proc in
      guard self?.serialBridgeProcess === proc else { return }
      self?.serialBridgeProcess = nil
      // A helper that dies almost immediately is broken; do not respawn it
      // in a loop. After a healthy run, bring it back shortly.
      if Date().timeIntervalSince(launchTime) >= 3 {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
          self?.ensureSerialBridgeRegistered(result: { _ in })
        }
      }
    }
    do {
      try process.run()
    } catch {
      result("error:\(error.localizedDescription)")
      return
    }
    serialBridgeProcess = process
    result("enabled")
  }
}
