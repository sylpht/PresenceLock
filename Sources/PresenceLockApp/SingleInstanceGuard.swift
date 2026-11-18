import Darwin
import Foundation

/// Holds a non-blocking advisory lock for the process lifetime so two copies cannot append to
/// the local JSONL journal at the same time.
final class SingleInstanceGuard {
    private let descriptor: Int32

    init?(directoryURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            return nil
        }

        let lockURL = directoryURL.appendingPathComponent(".instance.lock")
        let opened = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard opened >= 0 else { return nil }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(opened)
            return nil
        }
        _ = fchmod(opened, S_IRUSR | S_IWUSR)
        descriptor = opened
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
