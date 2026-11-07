import Foundation

/// Signs in with whatever the account uses: OAuth (XOAUTH2) or password. Call from connection queues only.
extension IMAPClient {
    func login(account: Account, select folder: String? = nil, readOnly: Bool = false, compress: Bool = false) throws {
        if account.oauth {
            try authenticateXOAUTH2(user: account.username, token: OAuth.accessTokenBlocking(for: account))
            if let folder { try select(folder, readOnly: readOnly) }
        } else {
            try login(user: account.username, password: Keychain.password(for: account), select: folder, readOnly: readOnly, compress: compress)
        }
    }
}

extension SMTPClient {
    func login(account: Account) throws {
        if account.oauth { try loginXOAUTH2(user: account.username, token: OAuth.accessTokenBlocking(for: account)) }
        else { try login(user: account.username, password: Keychain.password(for: account)) }
    }
}
