import Foundation
import Security

/// S/MIME (RFC 8551) on top of the system CMS implementation; no third-party code.
/// Works on MIME "entities" (content headers + blank line + body, CRLF line ends), so the
/// caller decides how the result is wrapped into a message.
enum SMIME {
    enum SMIMEError: LocalizedError {
        case cms(String, OSStatus)
        case malformed(String)
        var errorDescription: String? {
            switch self {
            case .cms(let what, let s): return "\(what) failed (\(SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"))"
            case .malformed(let s): return "Malformed S/MIME message: \(s)"
            }
        }
    }

    struct Verification {
        /// The signature matches the content (the message was not altered).
        var signatureValid: Bool
        /// The signer's certificate chains to a trusted root and fits the sender address.
        var trusted: Bool
        var signerEmail: String?
        var certificate: SecCertificate?
        var detail: String
    }

    // MARK: canonical form and wrapping

    static func crlf(_ d: Data) -> Data {
        var out = Data(capacity: d.count + d.count / 40)
        var prev: UInt8 = 0
        for b in d {
            if b == 10 && prev != 13 { out.append(13) }
            out.append(b); prev = b
        }
        return out
    }

    private static func base64Lines(_ d: Data) -> Data {
        Data(d.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]).utf8)
    }

    // MARK: signing

    /// Detached signature (multipart/signed). Returns the Content-Type header value and the body.
    static func sign(entity: Data, identity: SecIdentity) throws -> (contentType: String, body: Data) {
        let content = crlf(entity)
        var out: CFData?
        let status = content.withUnsafeBytes {
            CMSEncodeContent(identity, nil, nil, true, [.attrSigningTime, .attrSmimeCapabilities], $0.baseAddress!, content.count, &out)
        }
        guard status == errSecSuccess, let der = out as Data? else { throw SMIMEError.cms("Signing", status) }
        let boundary = "----=_SMIME_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8)); body.append(content)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/pkcs7-signature; name=\"smime.p7s\"\r\nContent-Transfer-Encoding: base64\r\nContent-Disposition: attachment; filename=\"smime.p7s\"\r\n\r\n".utf8))
        body.append(base64Lines(der)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return ("multipart/signed; protocol=\"application/pkcs7-signature\"; micalg=sha-256; boundary=\"\(boundary)\"", body)
    }

    // MARK: encryption

    /// Encrypts for all recipient certificates (include the sender's own, so "Sent" stays readable).
    static func encrypt(entity: Data, recipients: [SecCertificate]) throws -> (contentType: String, body: Data) {
        guard !recipients.isEmpty else { throw SMIMEError.malformed("no recipients") }
        let content = crlf(entity)
        var out: CFData?
        let status = content.withUnsafeBytes {
            CMSEncodeContent(nil, recipients as CFArray, nil, false, [], $0.baseAddress!, content.count, &out)
        }
        guard status == errSecSuccess, let der = out as Data? else { throw SMIMEError.cms("Encryption", status) }
        return ("application/pkcs7-mime; smime-type=enveloped-data; name=\"smime.p7m\"", base64Lines(der) + Data("\r\n".utf8))
    }

    // MARK: decoding

    private static func decoder(_ data: Data, detached: Data?, keychain: SecKeychain?) throws -> CMSDecoder {
        var dec: CMSDecoder?
        var s = CMSDecoderCreate(&dec)
        guard s == errSecSuccess, let d = dec else { throw SMIMEError.cms("Decoder", s) }
        if let keychain { CMSDecoderSetSearchKeychain(d, [keychain] as CFArray) }
        if let detached {
            s = detached.withUnsafeBytes { _ in CMSDecoderSetDetachedContent(d, detached as CFData) }
            guard s == errSecSuccess else { throw SMIMEError.cms("Detached content", s) }
        }
        s = data.withUnsafeBytes { CMSDecoderUpdateMessage(d, $0.baseAddress!, data.count) }
        guard s == errSecSuccess else { throw SMIMEError.cms("Reading message", s) }
        s = CMSDecoderFinalizeMessage(d)
        guard s == errSecSuccess else { throw SMIMEError.cms("Finishing message", s) }
        return d
    }

    /// Decrypts `application/pkcs7-mime; smime-type=enveloped-data` (DER bytes, already base64-decoded).
    /// The private key must be in the keychain (pass `keychain` to search a specific one).
    static func decrypt(_ der: Data, keychain: SecKeychain? = nil) throws -> Data {
        let d = try decoder(der, detached: nil, keychain: keychain)
        var enc: DarwinBoolean = false
        CMSDecoderIsContentEncrypted(d, &enc)
        guard enc.boolValue else { throw SMIMEError.malformed("content is not encrypted") }
        var content: CFData?
        let s = CMSDecoderCopyContent(d, &content)
        guard s == errSecSuccess, let c = content as Data? else { throw SMIMEError.cms("Decryption", s) }
        return c
    }

    /// Checks a signature. `content` is the exact first part for multipart/signed; nil for opaque signed-data.
    static func verify(signature der: Data, content: Data?, trustPolicyEmail: String? = nil) throws -> (Verification, Data?) {
        let d = try decoder(der, detached: content.map(crlfIfNeeded), keychain: nil)
        var n = 0
        CMSDecoderGetNumSigners(d, &n)
        guard n > 0 else { return (Verification(signatureValid: false, trusted: false, signerEmail: nil, certificate: nil, detail: "No signature found"), nil) }
        var status = CMSSignerStatus.unsigned
        var cs = CMSDecoderCopySignerStatus(d, 0, SecPolicyCreateBasicX509(), false, &status, nil, nil)
        let valid = cs == errSecSuccess && status == .valid
        var email: CFString?
        CMSDecoderCopySignerEmailAddress(d, 0, &email)
        var cert: SecCertificate?
        CMSDecoderCopySignerCert(d, 0, &cert)
        // Trust: does the certificate chain to a trusted root and suit S/MIME for this address?
        var trusted = false
        var trustStatus = CMSSignerStatus.unsigned
        let address = trustPolicyEmail ?? (email as String?)
        let props: [CFString: Any] = address.map { [kSecPolicyName: $0] } ?? [:]
        let policy = SecPolicyCreateWithProperties(kSecPolicyAppleSMIME, props as CFDictionary) ?? SecPolicyCreateBasicX509()
        cs = CMSDecoderCopySignerStatus(d, 0, policy, true, &trustStatus, nil, nil)
        trusted = valid && cs == errSecSuccess && trustStatus == .valid
        var inner: CFData?
        if content == nil { CMSDecoderCopyContent(d, &inner) }
        let detail = !valid ? "Signature does not match the content" : trusted ? "Signature valid, certificate trusted" : "Signature valid, certificate not trusted"
        return (Verification(signatureValid: valid, trusted: trusted, signerEmail: email as String?, certificate: cert, detail: detail), inner as Data?)
    }

    private static func crlfIfNeeded(_ d: Data) -> Data { d }

    // MARK: multipart/signed parsing

    /// Splits a multipart/signed body into the signed content (exact bytes) and the decoded signature.
    static func splitSigned(body: Data, boundary: String) -> (content: Data, signature: Data)? {
        let open = Data("--\(boundary)\r\n".utf8)
        let mid = Data("\r\n--\(boundary)\r\n".utf8)
        guard let r1 = body.range(of: open), r1.lowerBound == body.startIndex || body[..<r1.lowerBound].allSatisfy({ $0 == 13 || $0 == 10 }) else { return nil }
        guard let r2 = body.range(of: mid, in: r1.upperBound..<body.endIndex) else { return nil }
        let content = body[r1.upperBound..<r2.lowerBound]
        let rest = body[r2.upperBound...]
        guard let hdrEnd = rest.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let end = rest.range(of: Data("\r\n--\(boundary)".utf8), in: hdrEnd.upperBound..<rest.endIndex)?.lowerBound ?? rest.endIndex
        let b64 = String(decoding: rest[hdrEnd.upperBound..<end], as: UTF8.self).filter { !$0.isWhitespace }
        guard let sig = Data(base64Encoded: b64) else { return nil }
        return (Data(content), sig)
    }
}
