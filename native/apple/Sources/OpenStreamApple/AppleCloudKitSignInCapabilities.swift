import Foundation
#if os(macOS)
import Security
#endif

@MainActor
enum AppleCloudKitSignInCapabilities {
    static let containerID = "iCloud.com.orgista.openstream"
    static let current = signedEntitlements()

    static var isEntitled: Bool { permitsCloudKit(current) }
    static var permitsPush: Bool {
        isEntitled && (current["aps-environment"] != nil || current["com.apple.developer.aps-environment"] != nil)
    }

    static func permitsCloudKit(_ entitlements: [String: Any]) -> Bool {
        missingCloudKitEntitlement(in: entitlements) == nil
    }

    static func missingCloudKitEntitlement(in entitlements: [String: Any]) -> String? {
        let service = "com.apple.developer.icloud-services"
        let containers = "com.apple.developer.icloud-container-identifiers"
        guard (entitlements[service] as? [String])?.contains("CloudKit") == true else { return service }
        guard (entitlements[containers] as? [String])?.contains(containerID) == true else { return containers }
        return nil
    }

    static let gateTrace: String = {
        let missing = missingCloudKitEntitlement(in: current)
        return "source sign-in sync: entitlement gate entitled=\(missing == nil) missing=\(missing ?? "none")"
    }()

    private static func signedEntitlements() -> [String: Any] {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else {
            appleTrace("source sign-in sync: entitlement read unavailable reason=no-security-task")
            return [:]
        }
        let keys = ["com.apple.developer.icloud-services", "com.apple.developer.icloud-container-identifiers",
                    "com.apple.developer.aps-environment"]
        return SecTaskCopyValuesForEntitlements(task, keys as CFArray, nil) as? [String: Any] ?? [:]
        #else
        // SecTask is macOS-only. Installed iOS/tvOS apps have a thin Mach-O;
        // read its signed XML entitlements without calling private APIs.
        return entitlements(executableURL: Bundle.main.executableURL)
        #endif
    }

    static func entitlements(executableURL: URL?) -> [String: Any] {
        guard let executableURL else {
            appleTrace("source sign-in sync: entitlement read unavailable reason=no-executable")
            return [:]
        }
        do {
            let values = entitlements(in: try Data(contentsOf: executableURL, options: .mappedIfSafe))
            if values.isEmpty { appleTrace("source sign-in sync: entitlement read unavailable reason=no-signed-xml") }
            return values
        } catch {
            appleTrace("source sign-in sync: entitlement read unavailable code=\((error as NSError).code)")
            return [:]
        }
    }

    static func entitlements(in executable: Data) -> [String: Any] {
        func word(_ offset: Int, bigEndian: Bool = false) -> Int? {
            guard offset >= 0, offset <= executable.count - 4 else { return nil }
            let bytes = executable[offset..<(offset + 4)]
            return (bigEndian ? Array(bytes) : Array(bytes.reversed())).reduce(0) { ($0 << 8) | Int($1) }
        }
        guard word(0) == 0xfeedfacf, let count = word(16), count <= 1_024,
              let commandBytes = word(20), commandBytes <= executable.count - 32 else { return [:] }
        let commandsEnd = 32 + commandBytes
        var offset = 32
        for _ in 0..<count {
            guard let command = word(offset), let size = word(offset + 4), size >= 8,
                  offset + size <= commandsEnd else { return [:] }
            defer { offset += size }
            guard command == 0x1d, size >= 16,
                  let signature = word(offset + 8), let signatureSize = word(offset + 12),
                  signatureSize >= 12, signature <= executable.count - signatureSize,
                  word(signature, bigEndian: true) == 0xfade0cc0,
                  let blobCount = word(signature + 8, bigEndian: true),
                  blobCount <= (signatureSize - 12) / 8 else { continue }
            for index in 0..<blobCount {
                let slot = signature + 12 + index * 8
                guard word(slot, bigEndian: true) == 5,
                      let relative = word(slot + 4, bigEndian: true), relative <= signatureSize - 8 else { continue }
                let blob = signature + relative
                guard word(blob, bigEndian: true) == 0xfade7171,
                      let length = word(blob + 4, bigEndian: true), length >= 8,
                      length <= signatureSize - relative else { continue }
                let xml = executable.subdata(in: (blob + 8)..<(blob + length))
                return (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any] ?? [:]
            }
        }
        return [:]
    }
}
