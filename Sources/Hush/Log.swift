import Foundation
import os

/// Plain-text log at ~/Library/Logs/Hush.log so problems can be diagnosed
/// after the fact. Bounded: at 1 MB the file rolls over to Hush.old.log.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Hush.log")

    private static let maxBytes = 1_000_000
    private static let system = Logger(subsystem: "com.zodwick.hush", category: "app")
    private static let queue = DispatchQueue(label: "com.zodwick.hush.log")
    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ category: String, _ message: String) {
        system.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        let line = "\(timestamp.string(from: Date())) [\(category)] \(message)\n"
        queue.async { append(line) }
    }

    static func hex<C: Collection<UInt8>>(_ bytes: C) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = url.deletingLastPathComponent().appendingPathComponent("Hush.old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
