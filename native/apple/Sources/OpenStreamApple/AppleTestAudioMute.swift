import Foundation

/// Debug-only: keeps every player silent so test runs on the owner's Mac make
/// no sound. On with `-OpenStreamMuteAudio YES` (simulator runs) and always
/// inside a test process (`swift test`, XCTest, UI-test runners), whatever
/// the defaults say. Release builds always answer `false`.
public enum AppleTestAudioMute {
    public static let isActive: Bool = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "OpenStreamMuteAudio") { return true }
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil || environment["OPENSTREAM_MUTE_AUDIO"] == "1" {
            return true
        }
        let process = ProcessInfo.processInfo.processName
        return process.contains("testing-helper") || process.hasSuffix("PackageTests") || process == "xctest"
        #else
        false
        #endif
    }()
}
