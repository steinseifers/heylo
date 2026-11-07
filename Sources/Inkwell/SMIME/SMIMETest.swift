import Foundation
import Security

/// `Inkwell --smimetest`: S/MIME round trips with a throw-away self-signed identity in a temporary keychain
/// (never touches the user's keychains). Needs /usr/bin/openssl to create the test certificate.
enum SMIMETest {
    static func sh(_ args: [String], in dir: URL) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); p.arguments = args; p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }

    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "✓ \(what)" : "✗ \(what)"); if !ok { failures += 1 } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smime-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cnf = """
        [req]
        distinguished_name=dn
        x509_extensions=ext
        prompt=no
        [dn]
        CN=Test User
        emailAddress=me@example.invalid
        [ext]
        subjectAltName=email:me@example.invalid
        keyUsage=digitalSignature,keyEncipherment
        extendedKeyUsage=emailProtection
        basicConstraints=CA:FALSE
        """
        try? cnf.write(to: dir.appendingPathComponent("o.cnf"), atomically: true, encoding: .utf8)
        guard sh(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "k.pem", "-out", "c.pem", "-days", "2", "-config", "o.cnf"], in: dir),
              sh(["pkcs12", "-export", "-inkey", "k.pem", "-in", "c.pem", "-out", "t.p12", "-passout", "pass:pw"], in: dir),
              let p12 = try? Data(contentsOf: dir.appendingPathComponent("t.p12")) else { print("✗ could not create the test certificate with openssl"); exit(1) }

        var kc: SecKeychain?
        let kcPath = dir.appendingPathComponent("test.keychain").path
        guard SecKeychainCreate(kcPath, 2, "pw", false, nil, &kc) == errSecSuccess, let keychain = kc else { print("✗ temporary keychain"); exit(1) }
        SecKeychainUnlock(keychain, 2, "pw", true)
        // CMSDecoder finds private keys through the keychain search list: add the temporary keychain
        // for the duration of the test and restore the user's list afterwards.
        var oldList: CFArray?
        SecKeychainCopySearchList(&oldList)
        SecKeychainSetSearchList(([keychain] + ((oldList as? [SecKeychain]) ?? [])) as CFArray)
        defer { if let oldList { SecKeychainSetSearchList(oldList) } }
        var items: CFArray?
        let st = SecPKCS12Import(p12 as CFData, [kSecImportExportPassphrase: "pw", kSecImportExportKeychain: keychain] as CFDictionary, &items)
        guard st == errSecSuccess, let first = (items as? [[String: Any]])?.first, let identityAny = first[kSecImportItemIdentity as String] else { print("✗ import identity (\(st))"); exit(1) }
        let identity = identityAny as! SecIdentity
        var certRef: SecCertificate?
        SecIdentityCopyCertificate(identity, &certRef)
        guard let cert = certRef else { exit(1) }

        let entity = Data("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\nHello, this is confidential. Umlaute: äöüß\r\n".utf8)
        do {
            // 1. Sign and verify.
            let signed = try SMIME.sign(entity: entity, identity: identity)
            let boundary = signed.contentType.components(separatedBy: "boundary=\"").last!.replacingOccurrences(of: "\"", with: "")
            check(signed.contentType.contains("multipart/signed") && signed.contentType.contains("sha-256"), "signed message is multipart/signed with sha-256")
            guard let parts = SMIME.splitSigned(body: signed.body, boundary: boundary) else { check(false, "split multipart/signed"); exit(1) }
            check(parts.content == entity, "signed part is the exact original entity")
            let (v, _) = try SMIME.verify(signature: parts.signature, content: parts.content)
            check(v.signatureValid, "signature verifies")
            check(v.signerEmail == "me@example.invalid", "signer address is read from the certificate")
            check(!v.trusted, "self-signed certificate is reported as not trusted")

            // 2. Tampering is detected.
            var tampered = parts.content; tampered[tampered.count - 4] ^= 0x01
            let (bad, _) = try SMIME.verify(signature: parts.signature, content: tampered)
            check(!bad.signatureValid, "altered content fails verification")

            // 3. Encrypt and decrypt.
            let enc = try SMIME.encrypt(entity: entity, recipients: [cert])
            check(enc.contentType.contains("enveloped-data"), "encrypted message is enveloped-data")
            let der = Data(base64Encoded: String(decoding: enc.body, as: UTF8.self).filter { !$0.isWhitespace })!
            if let dump = ProcessInfo.processInfo.environment["SMIME_DUMP"] { try? der.write(to: URL(fileURLWithPath: dump)) }
            check(!String(decoding: der, as: UTF8.self).contains("confidential"), "ciphertext does not contain the plain text")
            check(try SMIME.decrypt(der, keychain: keychain) == entity, "decryption returns the original entity")

            // 4. Sign, then encrypt (the usual order), and open it again.
            let both = try SMIME.encrypt(entity: Data("Content-Type: \(signed.contentType)\r\n\r\n".utf8) + signed.body, recipients: [cert])
            let der2 = Data(base64Encoded: String(decoding: both.body, as: UTF8.self).filter { !$0.isWhitespace })!
            let inner = try SMIME.decrypt(der2, keychain: keychain)
            let split = inner.range(of: Data("\r\n\r\n".utf8))!
            let innerParts = SMIME.splitSigned(body: inner[split.upperBound...], boundary: boundary)
            let innerOK = try innerParts.map { try SMIME.verify(signature: $0.signature, content: $0.content).0.signatureValid } ?? false
            check(innerOK, "signed + encrypted message opens and verifies")

            // 5. Whole messages: wrap for sending, open for display.
            SMIMEKeychain.rememberCertificates = false
            let plain = Data("From: Me <me@example.invalid>\r\nTo: you@example.invalid\r\nSubject: Test\r\nDate: Sat, 7 Nov 2026 12:00:00 +0100\r\nMessage-ID: <w1@example.invalid>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSecret plan: ship on Friday. Grüße\r\n".utf8)
            check(!SMIME.looksLikeSMIME(plain), "ordinary mail is not treated as S/MIME")
            let signedOnly = try SMIME.wrap(message: plain, signWith: identity, encryptTo: [])
            let so = SMIME.openForDisplay(signedOnly, keychain: keychain)
            check(so?.status.signed == true && so?.status.signatureValid == true && so?.status.encrypted == false, "signed message: signature valid, not encrypted")
            check(String(decoding: signedOnly, as: UTF8.self).contains("Subject: Test"), "headers stay readable in a signed message")
            let signedAndEncrypted = try SMIME.wrap(message: plain, signWith: identity, encryptTo: [cert])
            check(!String(decoding: signedAndEncrypted, as: UTF8.self).contains("Secret plan"), "encrypted message hides the content")
            check(String(decoding: signedAndEncrypted, as: UTF8.self).contains("Subject: Test"), "headers of an encrypted message stay readable")
            let bo = SMIME.openForDisplay(signedAndEncrypted, keychain: keychain)
            check(bo?.status.encrypted == true && bo?.status.signed == true && bo?.status.signatureValid == true, "signed + encrypted message opens: encrypted, signed, valid")
            check(bo.map { MIME.parse($0.message).text.contains("Secret plan: ship on Friday. Grüße") } == true, "decrypted text is available for display")
            check(bo.map { MIME.parse($0.message).subject == "Test" } == true, "decrypted message keeps the outer headers")
            let encOnly = try SMIME.wrap(message: plain, signWith: nil, encryptTo: [cert])
            let eo = SMIME.openForDisplay(encOnly, keychain: keychain)
            check(eo?.status.encrypted == true && eo?.status.signed == false, "encrypted-only message opens")
            var tamperedMsg = signedOnly
            if let r = tamperedMsg.range(of: Data("Secret plan".utf8)) { tamperedMsg[r.lowerBound] = UInt8(ascii: "X") }
            let tm = SMIME.openForDisplay(tamperedMsg, keychain: keychain)
            check(tm?.status.signed == true && tm?.status.signatureValid == false && tm?.status.problem != nil, "a changed signed message is flagged")
            // The stored raw message never contains plain text of an encrypted mail.
            check(!signedAndEncrypted.contains(Data("Secret plan".utf8)), "raw (stored) encrypted message has no plain text")
        } catch { check(false, "unexpected error: \(error.localizedDescription)") }
        if let oldList { SecKeychainSetSearchList(oldList) }
        SecKeychainDelete(keychain)
        print(failures == 0 ? "All S/MIME checks passed" : "S/MIME FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
