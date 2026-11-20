import CryptoKit
import Darwin
import Foundation

// "Set up this device from your iPhone": a one-time, LAN-only hand-over of
// the whole configuration (sources, sign-ins, settings), end-to-end encrypted
// to a key the receiving device shows in its QR code. The wire format is
// documented in HANDOFF-NEXT-SESSION.md ("Setup transfer over the LAN") so
// another platform can receive it.

/// The QR code's content:
/// `openstream://send-setup?h=<host:port>&s=<session>&k=<receiver key>&c=<code>`.
/// Parsed strictly; anything that is not a private-network address, a
/// 16-byte session id, a 32-byte X25519 key and an 8-character code is refused.
public struct AppleSetupTransferLink: Equatable, Hashable, Identifiable, Sendable {
    /// Host name or address without brackets (`192.168.1.20`, `fd00::1`, `tv.local`).
    public let hostName: String
    public let port: Int
    /// 16 random bytes, base64url without padding (22 characters).
    public let sessionID: String
    /// The receiver's X25519 public key, 32 bytes.
    public let receiverKey: Data
    /// 8 characters from `AppleWebManagementProtocol.makePairingCode`'s alphabet.
    public let code: String

    public var id: String { sessionID }

    static let codeAlphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// No validation: for a receiver building its own link and for tests.
    init(hostName: String, port: Int, sessionID: String, receiverKey: Data, code: String) {
        self.hostName = hostName
        self.port = port
        self.sessionID = sessionID
        self.receiverKey = receiverKey
        self.code = code
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "openstream", url.host?.lowercased() == "send-setup",
              url.user == nil, url.password == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.absoluteString.utf8.count <= 512,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var values: [String: String] = [:]
        for item in items {
            guard ["h", "s", "k", "c", "v"].contains(item.name), values[item.name] == nil,
                  let value = item.value else { return nil }
            values[item.name] = value
        }
        if let version = values["v"], version != "1" { return nil }
        guard let address = values["h"], let (host, port) = Self.parseAddress(address),
              let session = values["s"], Self.isSessionID(session),
              let keyText = values["k"], keyText.utf8.count == 43,
              let key = AppleSetupTransferBase64URL.decode(keyText), key.count == 32,
              let code = values["c"], code.count == 8, code.allSatisfy(Self.codeAlphabet.contains) else { return nil }
        self.init(hostName: host, port: port, sessionID: session, receiverKey: key, code: code)
    }

    /// `host:port`, IPv6 in brackets.
    public var address: String {
        hostName.contains(":") ? "[\(hostName)]:\(port)" : "\(hostName):\(port)"
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "openstream"
        components.host = "send-setup"
        components.queryItems = [
            URLQueryItem(name: "h", value: address),
            URLQueryItem(name: "s", value: sessionID),
            URLQueryItem(name: "k", value: AppleSetupTransferBase64URL.encode(receiverKey)),
            URLQueryItem(name: "c", value: code),
        ]
        // Every value is from a URL-safe alphabet; `[`, `]` and `:` are legal in a query.
        return components.url!
    }

    /// `http://<h>/setup/<s>`: GET for the receiver's name, POST for the setup.
    public var endpoint: URL {
        URL(string: "http://\(address)/setup/\(sessionID)")!
    }

    static func isSessionID(_ value: String) -> Bool {
        value.utf8.count == 22 && AppleSetupTransferBase64URL.decode(value)?.count == 16
    }

    /// Splits `h` into host and port and keeps it only when it names this
    /// network: a private or link-local IPv4 address, a unique-local or
    /// link-local IPv6 address, or a `.local` name. Ports below 1024 are refused.
    static func parseAddress(_ value: String) -> (String, Int)? {
        guard !value.isEmpty, value.utf8.count <= 80 else { return nil }
        let host: String
        let portText: String
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"),
                  value[value.index(after: close)...].hasPrefix(":") else { return nil }
            host = String(value[value.index(after: value.startIndex) ..< close])
            portText = String(value[value.index(close, offsetBy: 2)...])
            guard isLANIPv6(host) else { return nil }
        } else {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            host = String(parts[0]).lowercased()
            portText = String(parts[1])
            guard isLANIPv4(host) || isLocalName(host) else { return nil }
        }
        guard !portText.isEmpty, portText.count <= 5, portText.allSatisfy(\.isASCII), portText.allSatisfy(\.isNumber),
              let port = Int(portText), (1024 ... 65535).contains(port) else { return nil }
        return (host, port)
    }

    static func isLANIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16 ... 31): return true
        default: return false
        }
    }

    static func isLANIPv6(_ host: String) -> Bool {
        guard !host.contains("%") else { return false }
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
        return withUnsafeBytes(of: &address) { bytes in
            (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
        }
    }

    static func isLocalName(_ host: String) -> Bool {
        guard host.hasSuffix(".local"), host.utf8.count <= 63 else { return false }
        let labels = host.dropLast(".local".count).split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty && labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

enum AppleSetupTransferBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    static func random(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return encode(Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
}

/// What the sender POSTs: `{"v":1,"senderKey":"…","sealed":"…"}`, both values
/// base64url. The one-time code travels in the `X-Setup-Code` header.
public struct AppleSetupTransferRequest: Codable, Equatable, Sendable {
    public var v: Int
    public var senderKey: String
    public var sealed: String
}

/// The decrypted body: the same snapshot and sign-ins a full backup carries.
public struct AppleSetupTransferPayload: Codable, Equatable, Sendable {
    public var v: Int
    /// The sender's device name, for "Import setup from <sender>?".
    public var sender: String
    public var snapshot: AppleConfigurationSnapshot
    public var secrets: AppleConfigurationSecrets

    public init(sender: String, snapshot: AppleConfigurationSnapshot, secrets: AppleConfigurationSecrets) {
        v = 1
        self.sender = sender
        self.snapshot = snapshot
        self.secrets = secrets
    }
}

/// The receiver's `GET /setup/<s>` answer: `{"v":1,"name":"Living Room"}`.
public struct AppleSetupTransferInfo: Codable, Equatable, Sendable {
    public var v: Int
    public var name: String
}

enum AppleSetupTransferError: Error, Equatable, LocalizedError {
    case unreadable
    case tooLarge
    case rejected(Int)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .unreadable: "The setup could not be read."
        case .tooLarge: "This setup is too large to send."
        case .rejected(404), .rejected(410): "This code has expired. Show a new one on the other device."
        case .rejected(429): "Too many tries. Show a new code on the other device."
        case .rejected: "The other device turned the setup down."
        case .unreachable: "Couldn’t reach the other device. Check that both are on the same network."
        }
    }
}

/// X25519 → HKDF-SHA256 → AES-256-GCM. The receiver's key comes from the QR
/// code, so the body is private even over plain HTTP on the LAN.
enum AppleSetupTransferCrypto {
    static let version = 1
    static let label = "openstream-setup-v1"

    static func key(shared: SharedSecret, sessionID: String, code: String,
                    senderKey: Data, receiverKey: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(label.utf8),
            sharedInfo: info(sessionID: sessionID, code: code, senderKey: senderKey, receiverKey: receiverKey),
            outputByteCount: 32)
    }

    /// `openstream-setup-v1|<s>|<c>|<sender key b64url>|<receiver key b64url>`
    static func info(sessionID: String, code: String, senderKey: Data, receiverKey: Data) -> Data {
        Data([label, sessionID, code, AppleSetupTransferBase64URL.encode(senderKey),
              AppleSetupTransferBase64URL.encode(receiverKey)].joined(separator: "|").utf8)
    }

    /// `openstream-setup-v1|<s>`
    static func associatedData(sessionID: String) -> Data {
        Data("\(label)|\(sessionID)".utf8)
    }

    static func seal(_ plaintext: Data, for link: AppleSetupTransferLink) throws -> AppleSetupTransferRequest {
        let receiver = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: link.receiverKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let senderKey = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: receiver)
        let key = key(shared: shared, sessionID: link.sessionID, code: link.code,
                      senderKey: senderKey, receiverKey: link.receiverKey)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(sessionID: link.sessionID))
        guard let combined = box.combined else { throw AppleSetupTransferError.unreadable }
        return AppleSetupTransferRequest(v: version, senderKey: AppleSetupTransferBase64URL.encode(senderKey),
                                         sealed: AppleSetupTransferBase64URL.encode(combined))
    }

    static func open(_ request: AppleSetupTransferRequest, receiver: Curve25519.KeyAgreement.PrivateKey,
                     sessionID: String, code: String) throws -> Data {
        guard request.v == version,
              let senderKey = AppleSetupTransferBase64URL.decode(request.senderKey), senderKey.count == 32,
              let sealed = AppleSetupTransferBase64URL.decode(request.sealed), sealed.count > 28 else {
            throw AppleSetupTransferError.unreadable
        }
        do {
            let shared = try receiver.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderKey))
            let key = key(shared: shared, sessionID: sessionID, code: code, senderKey: senderKey,
                          receiverKey: receiver.publicKey.rawRepresentation)
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key,
                                    authenticating: associatedData(sessionID: sessionID))
        } catch {
            throw AppleSetupTransferError.unreadable
        }
    }

    static func sealPayload(_ payload: AppleSetupTransferPayload, for link: AppleSetupTransferLink) throws -> Data {
        try payload.snapshot.validate()
        let request = try seal(AppleConfigurationSnapshot.encoder.encode(payload), for: link)
        let body = try JSONEncoder().encode(request)
        guard body.count <= AppleSetupReceiveSession.maximumBodyBytes else { throw AppleSetupTransferError.tooLarge }
        return body
    }
}

/// One receive session on the receiving device: its key, id, code and
/// lifetime, and the rules every POST is held to. Pure, so it is tested
/// without a socket.
struct AppleSetupReceiveSession {
    static let maximumAttempts = 5
    static let maximumBodyBytes = 4 * 1_024 * 1_024
    static let lifetime: TimeInterval = 10 * 60

    enum Rejection: Error, Equatable {
        case unknownSession, expired, consumed, tooManyAttempts, wrongCode, unreadable

        var status: (code: Int, text: String) {
            switch self {
            case .unknownSession: (404, "Not Found")
            case .expired, .consumed: (410, "Gone")
            case .tooManyAttempts: (429, "Too Many Requests")
            case .wrongCode: (403, "Forbidden")
            case .unreadable: (400, "Bad Request")
            }
        }
    }

    let privateKey: Curve25519.KeyAgreement.PrivateKey // gitleaks:allow (type declaration, no key material)
    let sessionID: String
    let code: String
    let expiresAt: Date
    private(set) var attempts = 0
    private(set) var consumed = false

    init(now: Date, lifetime: TimeInterval = Self.lifetime) {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        sessionID = AppleSetupTransferBase64URL.random(bytes: 16)
        code = AppleWebManagementProtocol.makePairingCode()
        expiresAt = now.addingTimeInterval(lifetime)
    }

    func link(host: String, port: Int) -> AppleSetupTransferLink {
        AppleSetupTransferLink(hostName: host, port: port, sessionID: sessionID,
                               receiverKey: privateKey.publicKey.rawRepresentation, code: code)
    }

    var isLocked: Bool { attempts >= Self.maximumAttempts }

    /// Whether `GET /setup/<s>` may answer: the right session, still open.
    func check(sessionID candidate: String, now: Date) -> Rejection? {
        guard AppleWebManagementProtocol.secretsMatch(candidate, sessionID) else { return .unknownSession }
        if consumed { return .consumed }
        if expiresAt <= now { return .expired }
        if isLocked { return .tooManyAttempts }
        return nil
    }

    /// A POST. A wrong code or a body that does not open counts toward the
    /// cap; the first good one closes the session.
    mutating func accept(sessionID candidate: String, code candidateCode: String?, body: Data,
                         now: Date) -> Result<AppleSetupTransferPayload, Rejection> {
        if let rejection = check(sessionID: candidate, now: now) { return .failure(rejection) }
        guard let candidateCode,
              AppleWebManagementProtocol.secretsMatch(candidateCode.uppercased(), code) else {
            attempts += 1
            return .failure(.wrongCode)
        }
        do {
            let request = try JSONDecoder().decode(AppleSetupTransferRequest.self, from: body)
            let plaintext = try AppleSetupTransferCrypto.open(request, receiver: privateKey,
                                                              sessionID: sessionID, code: code)
            let payload = try JSONDecoder().decode(AppleSetupTransferPayload.self, from: plaintext)
            guard payload.v == AppleSetupTransferCrypto.version else { throw AppleSetupTransferError.unreadable }
            try payload.snapshot.validate()
            consumed = true
            return .success(payload)
        } catch {
            attempts += 1
            return .failure(.unreadable)
        }
    }
}
