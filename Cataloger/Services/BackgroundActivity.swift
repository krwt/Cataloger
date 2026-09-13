import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Requests extra execution time from the system around work that must not be
/// interrupted partway through.
///
/// The "don't close the app yet" banner shown during bulk operations was only
/// ever a label — nothing actually kept the process alive. Without an
/// assertion, simply *backgrounding* the app mid-import can get it suspended
/// by iOS; the user doesn't have to force-quit for the write to be cut off.
///
/// This buys roughly 30 seconds of continued execution after backgrounding,
/// which is usually enough to finish a chunked CloudKit batch. It is not a
/// guarantee — the system can still terminate under memory pressure, and the
/// grace period is finite. The write-ahead ledger remains the actual
/// correctness mechanism; this just makes needing it far less likely.
enum BackgroundActivity {

    static func run<T>(_ name: String, operation: () async throws -> T) async rethrows -> T {
        #if canImport(UIKit)
        let taskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: name)
        }
        defer {
            if taskID != .invalid {
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(taskID)
                }
            }
        }
        return try await operation()
        #else
        return try await operation()
        #endif
    }
}
