import Foundation

enum Strategy: String, Codable {
    /// qswitch saves and restores the provider's credential files / keychain items itself.
    case snapshot
    /// The CLI supports multiple accounts natively; qswitch just runs its switch command.
    case command
}

struct KeychainRef: Codable, Equatable {
    var service: String
    var account: String?

    init(service: String, account: String?) {
        self.service = service
        self.account = account
    }

    /// Parses "service" or "service:account".
    init(spec: String) {
        if let i = spec.firstIndex(of: ":") {
            service = String(spec[..<i])
            account = String(spec[spec.index(after: i)...])
        } else {
            service = spec
            account = nil
        }
    }

    var display: String { account.map { "\(service):\($0)" } ?? service }
}

struct Provider: Codable {
    var name: String
    var description: String?
    var strategy: Strategy
    /// Interactive login command, run by `qswitch add`.
    var login: String?
    /// Snapshot strategy: files or directories (may start with ~) that hold the login.
    var files: [String] = []
    /// Snapshot strategy: keychain items that hold the login.
    var keychain: [KeychainRef] = []
    /// Command strategy: switch command; {account} and {profile} are substituted.
    var switchCommand: String?
    /// Prints the account identifier of the currently logged-in user.
    var accountCommand: String?
    /// Shows who is logged in (used by `qswitch whoami` and `status --verify`).
    var whoami: String?
}

struct Profile: Codable {
    var name: String
    /// Account identifier passed to the provider's switch command (command strategy).
    var account: String?
    /// Shell commands run after switching to this profile.
    var onSwitch: [String] = []
    var createdAt: Date
    var lastUsed: Date?
}

struct Config: Codable {
    var version = 1
    var providers: [String: Provider] = [:]
    var profiles: [String: [Profile]] = [:]
    var active: [String: String] = [:]

    func provider(_ name: String) throws -> Provider {
        guard let p = providers[name] else {
            throw QError("unknown provider '\(name)'. Known: \(providers.keys.sorted().joined(separator: ", "))")
        }
        return p
    }

    func profile(_ provider: String, _ name: String) throws -> Profile {
        guard let p = profiles[provider]?.first(where: { $0.name == name }) else {
            let known = (profiles[provider] ?? []).map(\.name)
            throw QError("no profile '\(name)' for \(provider)" + (known.isEmpty ? "" : ". Known: \(known.joined(separator: ", "))"))
        }
        return p
    }

    mutating func upsert(_ profile: Profile, for provider: String) {
        var list = profiles[provider] ?? []
        if let i = list.firstIndex(where: { $0.name == profile.name }) {
            list[i] = profile
        } else {
            list.append(profile)
        }
        profiles[provider] = list
    }
}

enum Paths {
    static var home: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
    }

    /// Root for qswitch state. Override with QSWITCH_HOME (used by the e2e tests).
    static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["QSWITCH_HOME"] {
            return URL(fileURLWithPath: custom)
        }
        return home.appendingPathComponent(".config/qswitch")
    }

    static var configFile: URL { root.appendingPathComponent("config.json") }
    static var vault: URL { root.appendingPathComponent("vault") }
    static var lockFile: URL { root.appendingPathComponent(".lock") }

    static func snapshot(provider: String, profile: String) -> URL {
        vault.appendingPathComponent(provider).appendingPathComponent("\(profile).snap")
    }

    static func expand(_ path: String) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }
}

enum Store {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load() throws -> Config {
        let url = Paths.configFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            var config = Config()
            for p in Builtins.providers { config.providers[p.name] = p }
            try save(config)
            return config
        }
        do {
            return try decoder.decode(Config.self, from: Data(contentsOf: url))
        } catch {
            throw QError("could not parse \(url.path): \(error)")
        }
    }

    static func save(_ config: Config) throws {
        try FS.writeAtomically(try encoder.encode(config), to: Paths.configFile, mode: 0o600)
    }

    /// Serialises qswitch invocations so two switches can't interleave file writes.
    static func withLock<T>(_ body: () throws -> T) throws -> T {
        try FS.ensureDir(Paths.root)
        let fd = open(Paths.lockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw QError("cannot open lock file \(Paths.lockFile.path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw QError("cannot acquire lock") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

enum FS {
    static func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func writeAtomically(_ data: Data, to url: URL, mode: Int) throws {
        try ensureDir(url.deletingLastPathComponent())
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).qswitch-tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw QError("cannot write \(tmp.path)")
        }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw QError("cannot replace \(url.path): \(String(cString: strerror(errno)))")
        }
    }
}

// Hand-written decoders so hand-edited config.json may omit list fields.
extension Provider {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        strategy = try c.decodeIfPresent(Strategy.self, forKey: .strategy) ?? .snapshot
        login = try c.decodeIfPresent(String.self, forKey: .login)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        keychain = try c.decodeIfPresent([KeychainRef].self, forKey: .keychain) ?? []
        switchCommand = try c.decodeIfPresent(String.self, forKey: .switchCommand)
        accountCommand = try c.decodeIfPresent(String.self, forKey: .accountCommand)
        whoami = try c.decodeIfPresent(String.self, forKey: .whoami)
    }
}

extension Profile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        account = try c.decodeIfPresent(String.self, forKey: .account)
        onSwitch = try c.decodeIfPresent([String].self, forKey: .onSwitch) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
    }
}
