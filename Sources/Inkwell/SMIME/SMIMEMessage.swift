import Foundation
import Security

/// What the conversation view shows about a message's S/MIME state.
struct SMIMEStatus: Equatable {
    var encrypted = false
    var signed = false
    var signatureValid = false
    var trusted = false
    var signerEmail: String?
    /// Set when decryption or verification could not be done (shown to the user).
    var problem: String?
}

extension SMIME {
    // MARK: whole messages

    /// Splits a message into header text and body bytes.
    static func split(_ message: Data) -> (head: String, body: Data)? {
        guard let r = message.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return (String(decoding: message[..<r.lowerBound], as: UTF8.self), Data(message[r.upperBound...]))
    }

    private static let entityHeaderNames: Set<String> = ["content-type", "content-transfer-encoding", "content-disposition", "content-id", "content-description"]

    /// Separates unfolded header blocks into message-level lines and content (entity) lines.
    private static func partition(_ head: String) -> (outer: [String], entity: [String]) {
        var outer: [String] = [], entity: [String] = []
        var current: [String] = [], isEntity = false
        func flush() { if !current.isEmpty { (isEntity ? { entity += current } : { outer += current })() }; current = [] }
        for line in head.components(separatedBy: "\r\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") { current.append(line); continue }
            flush()
            isEntity = entityHeaderNames.contains(line.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? "")
            current = [line]
        }
        flush()
        return (outer, entity)
    }

    /// Signs and/or encrypts a complete RFC 822 message (sign first, then encrypt). Message-level headers
    /// (From, To, Subject …) stay readable; the content is wrapped. Returns the message unchanged if neither is requested.
    static func wrap(message: Data, signWith identity: SecIdentity?, encryptTo recipients: [SecCertificate]) throws -> Data {
        guard identity != nil || !recipients.isEmpty else { return message }
        guard let (head, body) = split(crlf(message)) else { throw SMIMEError.malformed("no header/body separator") }
        let parts = partition(head)
        var entity = Data((parts.entity.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
        if let identity {
            let s = try sign(entity: entity, identity: identity)
            entity = Data("Content-Type: \(s.contentType)\r\n\r\n".utf8) + s.body
        }
        if !recipients.isEmpty {
            let e = try encrypt(entity: entity, recipients: recipients)
            entity = Data("Content-Type: \(e.contentType)\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"smime.p7m\"\r\n\r\n".utf8) + e.body
        }
        return Data((parts.outer.joined(separator: "\r\n") + "\r\n").utf8) + entity
    }

    // MARK: reading (display only)

    /// Cheap pre-check on the header block, so ordinary mail never pays for S/MIME handling.
    static func looksLikeSMIME(_ raw: Data) -> Bool {
        let end = raw.range(of: Data("\r\n\r\n".utf8))?.lowerBound ?? raw.count
        let s = String(decoding: raw.prefix(min(end, 16384)), as: UTF8.self).lowercased()
        return s.contains("pkcs7-mime") || (s.contains("multipart/signed") && s.contains("pkcs7"))
    }

    /// Opens an S/MIME message for display: verifies signatures and decrypts. Decrypted content is returned to the
    /// caller only; it must never be written to the database, cache or search index.
    static func openForDisplay(_ raw: Data, keychain: SecKeychain? = nil, depth: Int = 0) -> (message: Data, status: SMIMEStatus)? {
        guard depth < 3, looksLikeSMIME(raw), let (head, body) = split(raw) else { return nil }
        let headers = MIME.parseHeaders(Data(head.utf8))
        func h(_ n: String) -> String { headers.first { $0.0.caseInsensitiveCompare(n) == .orderedSame }?.1 ?? "" }
        let (type, params) = MIME.parseParams(h("Content-Type"))
        let from = MIME.parseAddressList(h("From")).first?.email
        let lowerType = type.lowercased()
        var status = SMIMEStatus()

        func outerHeaders() -> String { partition(head).outer.joined(separator: "\r\n") }
        func replaceContent(with entity: Data) -> Data { Data((outerHeaders() + "\r\n").utf8) + entity }

        if lowerType == "multipart/signed", (params["protocol"] ?? "").lowercased().contains("pkcs7"), let boundary = params["boundary"] {
            status.signed = true
            guard let parts = splitSigned(body: body, boundary: boundary) else { status.problem = "The signature could not be read."; return (raw, status) }
            if let (v, _) = try? verify(signature: parts.signature, content: parts.content, trustPolicyEmail: from) {
                status.signatureValid = v.signatureValid; status.trusted = v.trusted; status.signerEmail = v.signerEmail
                if !v.signatureValid { status.problem = "The message was changed after it was signed." }
                if v.signatureValid, let cert = v.certificate, let addr = v.signerEmail, addr.caseInsensitiveCompare(from ?? "") == .orderedSame { SMIMEKeychain.remember(cert) }
            } else { status.problem = "The signature could not be checked." }
            return (raw, status)
        }
        if lowerType == "application/pkcs7-mime" {
            let encoding = h("Content-Transfer-Encoding").lowercased()
            let der = encoding.contains("base64") ? Data(base64Encoded: String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }) : body
            guard let der else { status.problem = "The S/MIME data could not be read."; return (raw, status) }
            let kind = (params["smime-type"] ?? "").lowercased()
            if kind == "enveloped-data" || kind.isEmpty {
                status.encrypted = true
                guard let inner = try? decrypt(der, keychain: keychain) else {
                    status.problem = "This message is encrypted for a certificate that isn't on this Mac."
                    return (raw, status)
                }
                let message = replaceContent(with: inner)
                if let (m2, s2) = openForDisplay(message, keychain: keychain, depth: depth + 1) {
                    var merged = s2; merged.encrypted = true
                    return (m2, merged)
                }
                return (message, status)
            }
            if kind == "signed-data" {
                status.signed = true
                if let (v, content) = try? verify(signature: der, content: nil, trustPolicyEmail: from), let content {
                    status.signatureValid = v.signatureValid; status.trusted = v.trusted; status.signerEmail = v.signerEmail
                    return (replaceContent(with: content), status)
                }
                status.problem = "The signature could not be checked."
            }
        }
        return (raw, status)
    }
}

// MARK: keychain lookups

enum SMIMEKeychain {
    private static func emails(of cert: SecCertificate) -> [String] {
        var out: CFArray?
        guard SecCertificateCopyEmailAddresses(cert, &out) == errSecSuccess else { return [] }
        return ((out as? [String]) ?? []).map { $0.lowercased() }
    }

    private static func notExpired(_ cert: SecCertificate) -> Bool {
        guard let d = SecCertificateCopyNotValidAfterDate(cert) as Date? else { return true }
        return d > Date()
    }

    /// The private identity for a sender address (certificate with its key), preferring the one valid longest.
    static func identity(for email: String) -> SecIdentity? {
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let all = out as? [SecIdentity] else { return nil }
        let want = email.lowercased()
        return all.compactMap { id -> (SecIdentity, Date)? in
            var cert: SecCertificate?
            SecIdentityCopyCertificate(id, &cert)
            guard let cert, emails(of: cert).contains(want), notExpired(cert) else { return nil }
            return (id, (SecCertificateCopyNotValidAfterDate(cert) as Date?) ?? .distantFuture)
        }.max { $0.1 < $1.1 }?.0
    }

    /// A certificate to encrypt for this address (from a signed mail or an imported identity).
    static func certificate(for email: String) -> SecCertificate? {
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let all = out as? [SecCertificate] else { return nil }
        let want = email.lowercased()
        return all.filter { emails(of: $0).contains(want) && notExpired($0) }
            .max { ((SecCertificateCopyNotValidAfterDate($0) as Date?) ?? .distantPast) < ((SecCertificateCopyNotValidAfterDate($1) as Date?) ?? .distantPast) }
    }

    /// Tests switch this off so they never write to the user's keychain.
    nonisolated(unsafe) static var rememberCertificates = true

    /// Keeps a sender's certificate from a validly signed mail so we can encrypt to them later (as Apple Mail does).
    static func remember(_ cert: SecCertificate) {
        guard rememberCertificates else { return }
        _ = SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert] as CFDictionary, nil)  // duplicates are ignored
    }
}

extension MIME {
    /// Parser entry for showing a message to the user: opens S/MIME (verify, decrypt) first. Indexing, rules and
    /// previews keep using `parse`, so decrypted text never reaches the database or search index.
    static func parseForDisplay(_ raw: Data) -> ParsedMessage {
        guard let (message, status) = SMIME.openForDisplay(raw) else { return parse(raw) }
        var p = parse(message)
        p.smime = status
        p.attachments.removeAll { $0.filename.lowercased() == "smime.p7s" || $0.mimeType.lowercased().contains("pkcs7-signature") }
        return p
    }
}
