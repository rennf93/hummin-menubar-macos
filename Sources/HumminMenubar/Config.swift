import Foundation

// One manageable server endpoint. All command strings are executed through the
// user's login shell, so a servers.json is trusted code by definition: treat
// it like your shell profile and never install one you have not read.
struct Server: Codable, Hashable {
    var id: String
    var label: String
    var host: String
    var port: UInt16?
    var up: String
    var down: String
    var health: String
    var mutexGroup: String?
    // Optional replay-trim mode switcher (e.g. for LLM gateways whose config
    // is a mode file re-read per request). modes lists the choices, modeGet
    // prints the current one, modeSet contains a {mode} placeholder.
    var modes: [String]?
    var modeGet: String?
    var modeSet: String?
}

struct MenubarConfig: Codable {
    var hostOrder: [String]
    var servers: [Server]
}

enum Config {
    static let configFileName = "servers.json"

    static var searchPaths: [String] {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["HUMMIN_MENUBAR_CONFIG"], !env.isEmpty {
            paths.append(env)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        paths.append(home + "/.config/hummin-menubar/" + configFileName)
        paths.append(configFileName)
        return paths
    }

    static var logsDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs"
    }

    // Returns the parsed config plus the path it was loaded from.
    static func load() -> Result<(MenubarConfig, String), ConfigError> {
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

    enum ConfigError: LocalizedError {
        case notFound(paths: [String])
        case invalid(path: String, message: String)

        var errorDescription: String? {
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
