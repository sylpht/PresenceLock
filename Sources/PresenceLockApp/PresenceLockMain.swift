import AppKit

@main
enum PresenceLockMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var instanceGuard: SingleInstanceGuard?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let acquiredGuard = SingleInstanceGuard(directoryURL: AppController.dataDirectory()) else {
            NSApplication.shared.terminate(nil)
            return
        }
        instanceGuard = acquiredGuard
        controller = AppController()
        controller?.start()
        if CommandLine.arguments.contains("--camera-preview") {
            controller?.openCameraPreview()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
