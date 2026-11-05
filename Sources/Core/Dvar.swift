import Foundation

enum Dvar {
    /// Single source of truth for the version; the Makefile copies it into Info.plist.
    static let version = "0.2.0"
    static let bundleID = "com.dhruv9449.dvar"
}

struct DvarError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Every file Dvar reads or writes. Tests redirect them with environment variables.
enum Paths {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static var config: URL {
        override("DVAR_CONFIG") ?? home.appending(path: ".config/dvar/config.json")
    }

    /// Holds the config and the cached profile lists.
    static var supportDirectory: URL {
        config.deletingLastPathComponent()
    }

    static var log: URL {
        home.appending(path: "Library/Logs/dvar.log")
    }

    /// Replaces a browser's "Local State" file, so tests can use a fake profile list.
    static var localStateOverride: URL? {
        override("DVAR_LOCAL_STATE")
    }

    private static func override(_ key: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }
}
