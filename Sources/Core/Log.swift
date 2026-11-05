import Foundation

/// One line per routed link in ~/Library/Logs/dvar.log.
enum Log {
    private static let maxSize = 1_000_000

    static func append(_ line: String) {
        let path = Paths.log
        let data = Data("\(Date().formatted(.iso8601)) \(line)\n".utf8)
        let fileManager = FileManager.default

        // Start over once the log passes 1 MB rather than rotating.
        if let size = try? fileManager.attributesOfItem(atPath: path.path)[.size] as? Int, size > maxSize {
            try? fileManager.removeItem(at: path)
        }
        guard let handle = try? FileHandle(forWritingTo: path) else {
            try? data.write(to: path)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
