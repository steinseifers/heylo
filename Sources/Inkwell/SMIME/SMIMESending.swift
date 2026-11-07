import Foundation
import Security

/// Decides and applies S/MIME for outgoing mail, with Apple Mail's defaults: sign when the sender has a
/// certificate, encrypt when certificates for all recipients are available. The sender is always an extra
/// recipient, so the copy in Sent stays readable.
enum SMIMESending {
    struct Plan: Equatable {
        var sign: Bool
        var encrypt: Bool
        /// Certificates exist for every recipient (and for the sender), so encryption is possible.
        var canEncrypt: Bool
        var canSign: Bool
        var missingCertificates: [String]
    }

    enum Failure: LocalizedError {
        case noIdentity(String)
        case missingCertificates([String])
        var errorDescription: String? {
            switch self {
            case .noIdentity(let a): return "There is no S/MIME certificate with a private key for \(a) on this Mac, so the message can't be signed."
            case .missingCertificates(let l): return "Can't encrypt: no S/MIME certificate for \(l.joined(separator: ", ")). Ask them to send you a signed message first."
            }
        }
    }

    static let headerName = "X-Inkwell-SMIME"

    // The keychain is slow to query; the compose window asks often.
    nonisolated(unsafe) private static var cache: [String: (at: Date, found: Bool)] = [:]
    private static let lock = NSLock()
    private static func cached(_ key: String, _ lookup: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key], Date().timeIntervalSince(c.at) < 30 { return c.found }
        let v = lookup(); cache[key] = (Date(), v); return v
    }
    static func hasIdentity(_ email: String) -> Bool { cached("i:" + email.lowercased()) { SMIMEKeychain.identity(for: email) != nil } }
    static func hasCertificate(_ email: String) -> Bool { cached("c:" + email.lowercased()) { SMIMEKeychain.certificate(for: email) != nil || SMIMEKeychain.identity(for: email) != nil } }

    /// What will happen for this draft (user overrides win over the defaults).
    static func plan(for d: OutgoingDraft, from: String, recipients: [String]) -> Plan {
        let canSign = hasIdentity(from)
        let everyone = Array(Set(recipients.map { $0.lowercased() })) + [from.lowercased()]
        let missing = everyone.filter { !hasCertificate($0) }
        let canEncrypt = !recipients.isEmpty && missing.isEmpty
        return Plan(sign: canSign && (d.smimeSign ?? true), encrypt: canEncrypt && (d.smimeEncrypt ?? true), canEncrypt: canEncrypt, canSign: canSign, missingCertificates: missing)
    }

    /// Signs/encrypts a finished message according to the plan. Throws if something required is missing on this Mac.
    static func apply(_ data: Data, sign: Bool, encrypt: Bool, from: String, recipients: [String]) throws -> Data {
        guard sign || encrypt else { return data }
        var identity: SecIdentity?
        if sign {
            guard let id = SMIMEKeychain.identity(for: from) else { throw Failure.noIdentity(from) }
            identity = id
        }
        var certs: [SecCertificate] = []
        if encrypt {
            var missing: [String] = []
            for r in Array(Set((recipients + [from]).map { $0.lowercased() })) {
                if let c = SMIMEKeychain.certificate(for: r) { certs.append(c) }
                else if r == from.lowercased(), let id = SMIMEKeychain.identity(for: r) { var c: SecCertificate?; SecIdentityCopyCertificate(id, &c); if let c { certs.append(c) } }
                else { missing.append(r) }
            }
            if !missing.isEmpty { throw Failure.missingCertificates(missing) }
        }
        return try SMIME.wrap(message: data, signWith: identity, encryptTo: certs)
    }

    // MARK: scheduled messages carry the decision in a header; the sending Mac applies it

    static func marker(sign: Bool, encrypt: Bool) -> String? {
        let v = [sign ? "sign" : nil, encrypt ? "encrypt" : nil].compactMap { $0 }.joined(separator: " ")
        return v.isEmpty ? nil : v
    }

    /// Applies and removes the marker header of a stored scheduled message.
    static func applyMarker(to raw: Data, from: String, recipients: [String]) throws -> Data {
        guard let (head, body) = SMIME.split(raw) else { return raw }
        var keep: [String] = [], value = "", skipping = false
        for line in head.components(separatedBy: "\r\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") { if !skipping { keep.append(line) }; continue }
            skipping = line.lowercased().hasPrefix(headerName.lowercased() + ":")
            if skipping { value = String(line.dropFirst(headerName.count + 1)).trimmingCharacters(in: .whitespaces) } else { keep.append(line) }
        }
        let stripped = Data((keep.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
        return try apply(stripped, sign: value.contains("sign"), encrypt: value.contains("encrypt"), from: from, recipients: recipients)
    }
}
