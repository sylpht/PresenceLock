import AppKit
import Foundation

/// Reports whether macOS accepted the request. Launching a screen saver does not verify authentication.
final class ScreenLockExecutor {
    enum Result {
        case requested
        case failed(String)
    }

    private let screenSaver: URL
    private let displaySleepTool: URL

    init(
        screenSaver: URL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
        displaySleepTool: URL = URL(fileURLWithPath: "/usr/bin/pmset")
    ) {
        self.screenSaver = screenSaver
        self.displaySleepTool = displaySleepTool
    }

    func requestLock(completion: @escaping (Result) -> Void) {
        func finish(_ result: Result) {
            DispatchQueue.main.async { completion(result) }
        }
        if FileManager.default.fileExists(atPath: screenSaver.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: screenSaver, configuration: configuration) { app, error in
                if let error {
                    finish(.failed(error.localizedDescription))
                } else if app != nil {
                    finish(.requested)
                } else {
                    finish(.failed("macOS не подтвердила запуск заставки"))
                }
            }
            return
        }

        let process = Process()
        process.executableURL = displaySleepTool
        process.arguments = ["displaysleepnow"]
        process.terminationHandler = { task in
            if task.terminationReason == .exit && task.terminationStatus == 0 {
                finish(.requested)
            } else {
                finish(.failed("Команда выключения дисплея завершилась с кодом \(task.terminationStatus)"))
            }
        }
        do {
            try process.run()
        } catch {
            finish(.failed(error.localizedDescription))
        }
    }
}
