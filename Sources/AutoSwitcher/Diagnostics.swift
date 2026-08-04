//
//  Diagnostics.swift
//  AutoSwitcher
//
//  Bullet-proof logging that goes to BOTH:
//    - NSLog (unified log / Console.app)
//    - ~/Library/Logs/AutoSwitcher/debug.log (Apple-standard per-user logs
//      directory; visible in Console.app and Finder, survives reboot)
//
//  Why both: NSLog visibility in `log stream` depends on the unified-log
//  level (info vs default), on whether the user has the right filter, and
//  on whether other tools are buffering output. A plain log file always
//  works, doesn't require admin tools, and survives across restarts.
//

import Foundation

enum Diag {
    /// Standard Apple location for per-user app logs:
    ///   ~/Library/Logs/AutoSwitcher/debug.log
    /// Survives reboots, is auto-recognised by Console.app, and shows up
    /// in any standard "show logs" tool. Created lazily on first write.
    static let path: String = {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/AutoSwitcher")
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return (dir as NSString).appendingPathComponent("debug.log")
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let queue = DispatchQueue(label: "com.autoswitcher.diag", qos: .utility)

    /// PRIVACY: lines that contain the user's actual typed words go through
    /// logSensitive() and are dropped unless the user has explicitly enabled
    /// verbose logging in Settings. The default log carries only technical
    /// events (tap lifecycle, permission changes, correction counts).
    static var verboseEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.Keys.verboseLogging)
    }

    /// Log a line that includes typed-text content. No-op unless the user
    /// opted into verbose logging.
    static func logSensitive(_ message: String) {
        guard verboseEnabled else { return }
        log(message)
    }

    /// One-time per process: rotate the previous session's log to
    /// debug.log.prev instead of truncating it. Keeps the trail of a
    /// crashed session available for one more launch, and preserves the
    /// lines logged during singleton init (before the app delegate runs).
    private static let rotateOnce: Void = {
        let fm = FileManager.default
        let prev = path + ".prev"
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: prev)
            try? fm.moveItem(atPath: path, toPath: prev)
        }
    }()

    /// Append a line. Safe from any thread.
    ///
    /// Writes are dispatched to a serial utility queue, but each write
    /// flushes and closes the file handle so that if the process crashes
    /// the log up to the last completed call survives on disk. This is
    /// critical for debugging engine crashes — we need to see the LAST
    /// few entries even if the process never gets a chance to finish
    /// the next dispatch.
    static func log(_ message: String) {
        let line = "\(isoFormatter.string(from: Date()))  \(message)\n"
        // NSLog: unified log path.
        NSLog("AutoSwitcher: \(message)")
        // File path: append + sync. We use a sync barrier inside the queue
        // for the actual fsync so concurrent log calls don't interleave,
        // but the queue dispatch itself stays async so the caller doesn't
        // block.
        queue.async {
            _ = rotateOnce
            guard let data = line.data(using: .utf8) else { return }
            if let fh = FileHandle(forWritingAtPath: path) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                fh.write(data)
                // Force the bytes onto disk so a subsequent crash doesn't
                // wipe the last few log lines from the kernel write buffer.
                try? fh.synchronize()
            } else {
                try? line.write(toFile: path, atomically: false, encoding: .utf8)
            }
        }
    }
}
