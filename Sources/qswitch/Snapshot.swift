import CryptoKit
import Foundation

/// The saved login state of one profile: the contents of every tracked file and keychain item.
struct Snapshot: Codable {
    struct FileEntry: Codable {
        /// The provider's configured path (may start with ~).
        var path: String
        /// Path relative to `path` when `path` is a directory; nil for a plain file.
        var relative: String?
        var mode: Int
        var data: Data
    }

    struct KeychainEntry: Codable {
        var service: String
        var account: String
        var secret: Data
    }

    var capturedAt: Date
    var files: [FileEntry]
    /// Configured paths that were directories at capture time (restored as whole directories).
    var directories: [String]
    var keychain: [KeychainEntry]

    var isEmpty: Bool { files.isEmpty && directories.isEmpty && keychain.isEmpty }

    static let maxBytes = 5 * 1024 * 1024

    static func capture(_ provider: Provider) throws -> Snapshot {
        let fm = FileManager.default
        var files: [FileEntry] = []
        var dirs: [String] = []
        var total = 0

        for path in provider.files {
            let url = Paths.expand(path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                dirs.append(path)
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
                while let child = enumerator?.nextObject() as? URL {
                    guard (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    let rel = String(child.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count + 1))
                    let data = try Data(contentsOf: child)
                    total += data.count
                    files.append(FileEntry(path: path, relative: rel, mode: try mode(of: child), data: data))
                }
            } else {
                let data = try Data(contentsOf: url)
                total += data.count
                files.append(FileEntry(path: path, relative: nil, mode: try mode(of: url), data: data))
            }
            guard total <= maxBytes else {
                throw QError("snapshot of \(provider.name) exceeds \(maxBytes / 1024 / 1024) MB; track narrower paths than \(path)")
            }
        }

        var items: [KeychainEntry] = []
        for ref in provider.keychain {
            guard let secret = try Keychain.read(service: ref.service, account: ref.account) else { continue }
            guard let account = try ref.account ?? Keychain.account(service: ref.service) else {
                throw QError("could not determine keychain account for \(ref.service); configure it as service:account")
            }
            items.append(KeychainEntry(service: ref.service, account: account, secret: secret))
        }

        return Snapshot(capturedAt: Date(), files: files, directories: dirs, keychain: items)
    }

    /// Removes the provider's live login state (used before a fresh `add` login).
    static func clearLive(_ provider: Provider) throws {
        for path in provider.files {
            let url = Paths.expand(path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        for ref in provider.keychain {
            try Keychain.delete(service: ref.service, account: ref.account)
        }
    }

    /// Makes the live state match this snapshot exactly: tracked paths absent from the snapshot
    /// are removed, so switching to a profile never leaks another profile's credentials.
    func restore(_ provider: Provider) throws {
        let fm = FileManager.default
        for path in provider.files {
            let url = Paths.expand(path)
            let entries = files.filter { $0.path == path }
            if directories.contains(path) {
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                try FS.ensureDir(url)
                for e in entries {
                    try FS.writeAtomically(e.data, to: url.appendingPathComponent(e.relative ?? ""), mode: e.mode)
                }
            } else if let e = entries.first {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { try fm.removeItem(at: url) }
                try FS.writeAtomically(e.data, to: url, mode: e.mode)
            } else if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
        for ref in provider.keychain {
            if let e = keychain.first(where: { $0.service == ref.service && (ref.account == nil || $0.account == ref.account) }) {
                try Keychain.write(service: e.service, account: e.account, secret: e.secret)
            } else {
                try Keychain.delete(service: ref.service, account: ref.account)
            }
        }
    }

    private static func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    }
}

/// Encrypted on-disk storage for snapshots. Each snapshot is sealed with AES-GCM using a 256-bit
/// master key kept in the login keychain, so the vault files are useless without that key.
enum Vault {
    /// Override with QSWITCH_KEYCHAIN_SERVICE (used by the e2e tests).
    static var service: String {
        ProcessInfo.processInfo.environment["QSWITCH_KEYCHAIN_SERVICE"] ?? "qswitch"
    }
    static let keyAccount = "vault-master-key"

    private static func masterKey(create: Bool) throws -> SymmetricKey {
        if let hex = try Keychain.read(service: service, account: keyAccount) {
            guard let bytes = Data(hexString: String(decoding: hex, as: UTF8.self)), bytes.count == 32 else {
                throw QError("keychain item \(service)/\(keyAccount) is not a valid key")
            }
            return SymmetricKey(data: bytes)
        }
        guard create else { throw QError("vault key missing from keychain (\(service)/\(keyAccount)); saved profiles cannot be decrypted") }
        let key = SymmetricKey(size: .bits256)
        let hex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        try Keychain.write(service: service, account: keyAccount, secret: Data(hex.utf8))
        return key
    }

    static func save(_ snapshot: Snapshot, provider: String, profile: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plain = try encoder.encode(snapshot)
        let sealed = try AES.GCM.seal(plain, using: masterKey(create: true))
        guard let combined = sealed.combined else { throw QError("encryption failed") }
        try FS.writeAtomically(combined, to: Paths.snapshot(provider: provider, profile: profile), mode: 0o600)
    }

    static func load(provider: String, profile: String) throws -> Snapshot {
        let url = Paths.snapshot(provider: provider, profile: profile)
        guard let combined = try? Data(contentsOf: url) else {
            throw QError("no saved login for \(provider)/\(profile) at \(url.path)")
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain: Data
        do {
            plain = try AES.GCM.open(box, using: masterKey(create: false))
        } catch let e as QError {
            throw e
        } catch {
            throw QError("could not decrypt \(url.path): \(error)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Snapshot.self, from: plain)
    }

    static func delete(provider: String, profile: String) {
        try? FileManager.default.removeItem(at: Paths.snapshot(provider: provider, profile: profile))
    }

    static func rename(provider: String, from: String, to: String) throws {
        let src = Paths.snapshot(provider: provider, profile: from)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try FileManager.default.moveItem(at: src, to: Paths.snapshot(provider: provider, profile: to))
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        self.init(bytes)
    }
}
