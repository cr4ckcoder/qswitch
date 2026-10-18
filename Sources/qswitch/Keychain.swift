import Foundation

/// Thin wrapper over /usr/bin/security.
///
/// Going through the system `security` binary (instead of the Security framework) means item
/// ACLs trust a stable, Apple-signed path, so rebuilding qswitch never triggers keychain prompts.
/// Writes go over stdin (`security -i`) so secrets never appear in process arguments. That
/// interactive mode truncates lines at ~4 KB, so writes are capped at `maxSecretBytes`.
enum Keychain {
    static let securityPath = "/usr/bin/security"
    static let maxSecretBytes = 1900
    private static let notFound: Int32 = 44

    /// Optional keychain file to use instead of the default search list (QSWITCH_KEYCHAIN; e2e tests).
    private static var keychainFile: String? { ProcessInfo.processInfo.environment["QSWITCH_KEYCHAIN"] }
    private static var keychainArgs: [String] { keychainFile.map { [$0] } ?? [] }

    static func read(service: String, account: String?) throws -> Data? {
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        args.append("-w")
        let r = try Shell.capture(securityPath, args + keychainArgs)
        if r.status == notFound { return nil }
        guard r.status == 0 else {
            throw QError("keychain read failed for \(service): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        var data = r.stdout
        if data.last == 0x0A { data.removeLast() }
        return data
    }

    /// Looks up the account attribute of the first item matching `service`.
    static func account(service: String) throws -> String? {
        let r = try Shell.capture(securityPath, ["find-generic-password", "-s", service] + keychainArgs)
        guard r.status == 0 else { return nil }
        let text = r.out + r.err
        guard let range = text.range(of: "\"acct\"<blob>=\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func write(service: String, account: String, secret: Data) throws {
        guard secret.count <= maxSecretBytes else {
            throw QError("keychain secret for \(service) is \(secret.count) bytes; max supported is \(maxSecretBytes)")
        }
        for field in [service, account] + keychainArgs where field.contains("\"") || field.contains("\n") {
            throw QError("keychain service/account may not contain quotes or newlines: \(field)")
        }
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -X \(hex)\(keychainFile.map { " \"\($0)\"" } ?? "")\n"
        let r = try Shell.capture(securityPath, ["-i"], stdin: Data(line.utf8))
        guard r.status == 0, !r.err.contains("returned") else {
            throw QError("keychain write failed for \(service): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func delete(service: String, account: String?) throws {
        var args = ["delete-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        let r = try Shell.capture(securityPath, args + keychainArgs)
        guard r.status == 0 || r.status == notFound else {
            throw QError("keychain delete failed for \(service): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
