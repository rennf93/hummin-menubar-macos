import Foundation

// One manageable server endpoint. All command strings are executed through the
// user's login shell, so a servers.json is trusted code by definition: treat
// it like your shell profile and never install one you have not read.
public struct Server: Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var host: String
    public var port: UInt16?
    public var up: String
    public var down: String
    public var health: String
    public var mutexGroup: String?
    // Optional replay-trim mode switcher (e.g. for LLM gateways whose config
    // is a mode file re-read per request). modes lists the choices, modeGet
    // prints the current one, modeSet contains a {mode} placeholder.
    public var modes: [String]?
    public var modeGet: String?
    public var modeSet: String?

    public init(id: String, label: String, host: String, port: UInt16? = nil, up: String = "", down: String = "",
                health: String = "", mutexGroup: String? = nil, modes: [String]? = nil,
                modeGet: String? = nil, modeSet: String? = nil) {
        self.id = id; self.label = label; self.host = host; self.port = port
        self.up = up; self.down = down; self.health = health; self.mutexGroup = mutexGroup
        self.modes = modes; self.modeGet = modeGet; self.modeSet = modeSet
    }
}

public struct MenubarConfig: Codable, Sendable {
    public var hostOrder: [String]
    public var servers: [Server]
    public init(hostOrder: [String], servers: [Server]) { self.hostOrder = hostOrder; self.servers = servers }
}

public enum Config {
    public static let configFileName = "servers.json"

    public static var searchPaths: [String] {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["HUMMIN_MENUBAR_CONFIG"], !env.isEmpty {
            paths.append(env)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(home + "/.config/hummin-menubar/" + configFileName)
        paths.append(configFileName)
        return paths
    }

    // HUMMIN_MENUBAR_LOGS redirects logs (tests and the preview harness use it).
    public static var logsDirectory: String {
        if let env = ProcessInfo.processInfo.environment["HUMMIN_MENUBAR_LOGS"], !env.isEmpty { return env }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs"
    }

    // Returns the parsed config plus the path it was loaded from.
    public static func load() -> Result<(MenubarConfig, String), ConfigError> {
        for path in searchPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                let raw = try Data(contentsOf: URL(fileURLWithPath: path))
                let config = try JSONDecoder().decode(MenubarConfig.self, from: raw)
                return .success((config, path))
            } catch {
                return .failure(.invalid(path: path, message: error.localizedDescription))
            }
        }
        return .failure(.notFound(paths: searchPaths))
    }

    public enum ConfigError: LocalizedError {
        case notFound(paths: [String])
        case invalid(path: String, message: String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let paths):
                return """
                    No servers.json found. Looked in:
                    \(paths.joined(separator: "\n"))
                    Copy examples/servers.example.json to ~/.config/hummin-menubar/servers.json and edit it.
                    """
            case .invalid(let path, let message):
                return "servers.json at \(path) is invalid: \(message)"
            }
        }
    }
}
