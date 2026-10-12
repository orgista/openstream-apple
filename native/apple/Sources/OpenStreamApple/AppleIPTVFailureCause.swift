import Foundation

/// Why a Live TV provider did not answer, as the Live tab words it.
///
/// "Your Live TV account has reached its stream limit" must only appear when
/// the panel itself says so: its login reports `active_cons >= max_connections`
/// (`AppleIPTVAccountInfo.rejection`) or the status `MaxConnections`. A panel
/// that times out, refuses the connection or answers with a block page is
/// unreachable, and the viewer is told which provider could not be reached
/// (owner 2026-10-09: an IP block was read as a stream limit).
public enum AppleIPTVFailureCause: Equatable, Sendable {
    case streamLimit
    case unreachable
    case other

    public static func classify(_ error: any Error) -> Self {
        if let iptv = error as? AppleIPTVError {
            switch iptv {
            case .authenticationFailed(let status):
                let normalized = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized == "maxconnections" ? .streamLimit : .other
            case .unreachable, .httpStatus, .unexpectedResponse, .nonHTTPResponse:
                return .unreachable
            case .requestFailed(let status):
                return status >= 500 ? .unreachable : .other
            default:
                return .other
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .other
            default: return .unreachable
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return .unreachable }
        return .other
    }

    /// The Live tab's line for a playlist that failed, naming the provider.
    public static func message(for error: any Error, providerName: String) -> String {
        let name = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch classify(error) {
        case .unreachable:
            return name.isEmpty ? "Can’t reach your Live TV provider." : "Can’t reach \(name)."
        case .streamLimit, .other:
            let text = error.localizedDescription
            return name.isEmpty ? text : "\(name): \(text)"
        }
    }
}
