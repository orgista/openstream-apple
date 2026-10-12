import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// This device as the other end of Set Up from iPhone sees it.
@MainActor
enum AppleSetupTransferDevice {
    static var name: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    /// "this Apple TV" in the import question.
    static var noun: String {
        #if os(tvOS)
        "Apple TV"
        #elseif os(visionOS)
        "Apple Vision Pro"
        #elseif os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// The entry row's title. On an iPhone the sender is another iPhone.
    static var receiveTitle: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? "Set Up from Another iPhone" : "Set Up from iPhone"
        #else
        "Set Up from iPhone"
        #endif
    }
}

/// Owns the receiving session (QR → Import question → result) and the link a
/// scanned QR code opened on the sending device. One per app, like
/// `AppleAppIntentHandoff`, so any screen can open the receiver.
@MainActor
@Observable
final class AppleSetupTransferCenter {
    static let shared = AppleSetupTransferCenter()

    enum ReceiveStep: Equatable {
        case starting
        case waiting(AppleSetupTransferLink)
        case confirm(sender: String, sourceCount: Int)
        case importing
        case imported(Int)
        case failed(String)
    }

    var showsReceiver = false
    private(set) var receiveStep: ReceiveStep = .starting
    @ObservationIgnored private var server: AppleSetupReceiveServer?
    /// Held in memory only, between "received" and Import/Cancel.
    @ObservationIgnored private var received: AppleSetupTransferPayload?

    func presentReceiver() {
        appleTrace("setup receive: open")
        showsReceiver = true
    }

    func startReceiving() async {
        stopServer()
        received = nil
        receiveStep = .starting
        let fresh = AppleSetupReceiveServer(deviceName: AppleSetupTransferDevice.name)
        server = fresh
        fresh.onReceive = { [weak self] payload in
            guard let self else { return }
            self.received = payload
            self.receiveStep = .confirm(sender: payload.sender, sourceCount: payload.snapshot.sources.count)
            appleTrace("setup receive: asking to import \(payload.snapshot.sources.count) sources")
        }
        fresh.onStop = { [weak self, weak fresh] reason in
            guard let self, let fresh, self.server === fresh else { return }
            self.server = nil
            switch reason {
            case .expired: self.receiveStep = .failed("This code expired.")
            case .locked: self.receiveStep = .failed("Too many tries.")
            case .failed: self.receiveStep = .failed("The connection closed.")
            case .received, .stopped: break
            }
        }
        do {
            let link = try await fresh.start()
            guard server === fresh else { fresh.stop(); return }
            receiveStep = .waiting(link)
        } catch {
            guard server === fresh else { return }
            server = nil
            receiveStep = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn’t start.")
            appleTraceFailure("setup receive: could not start")
        }
    }

    func importReceived(into controller: AppleConfigurationController?) async {
        guard let payload = received, let controller else {
            appleTraceFailure("setup receive: import failed, \(received == nil ? "nothing received" : "still starting")")
            receiveStep = .failed("Couldn’t import this setup.")
            return
        }
        receiveStep = .importing
        appleTrace("setup receive: import")
        do {
            let count = try await controller.importSetupTransfer(payload)
            receiveStep = .imported(count)
        } catch {
            appleTraceFailure("setup receive: import failed: \(appleErrorLabel(error))")
            receiveStep = .failed("Couldn’t import this setup.")
        }
        received = nil
    }

    func endReceiving() {
        appleTrace("setup receive: close")
        stopServer()
        received = nil
        receiveStep = .starting
        showsReceiver = false
    }

    private func stopServer() {
        let active = server
        server = nil
        active?.onStop = nil
        active?.stop()
    }
}

/// Hosts both ends at the app's root: the receiver opened from Settings and
/// the send question a scanned QR code opened (`AppleAppRouter.setupSendLink`).
struct AppleSetupTransferHost: ViewModifier {
    let router: AppleAppRouter
    let controller: AppleConfigurationController?
    @State private var center = AppleSetupTransferCenter.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { center.showsReceiver },
                set: { if !$0 { center.endReceiving() } }
            )) {
                AppleSetupReceiveView(center: center, controller: controller)
            }
            .sheet(item: Binding(
                get: { router.setupSendLink },
                set: { if $0 == nil { router.clearSetupSendLink() } }
            )) { link in
                AppleSetupSendView(link: link, controller: controller) { router.clearSetupSendLink() }
            }
            #if DEBUG
            .task {
                // End-to-end hook: open the receiver at launch.
                if UserDefaults.standard.bool(forKey: "OpenStreamDebugSetupReceive") { center.presentReceiver() }
                // …and the sending side: the QR's link without the system's
                // "Open in oStream?" prompt that `simctl openurl` raises.
                if let text = UserDefaults.standard.string(forKey: "OpenStreamDebugSetupLink"),
                   let url = URL(string: text) { router.open(url) }
            }
            #endif
    }
}

/// The receiving device: a QR code to scan, then "Import setup from …?".
struct AppleSetupReceiveView: View {
    let center: AppleSetupTransferCenter
    let controller: AppleConfigurationController?

    var body: some View {
        VStack(spacing: 32) {
            switch center.receiveStep {
            case .starting:
                ProgressView()
            case .waiting(let link):
                Text("Scan with your iPhone")
                    .font(.title2.weight(.semibold))
                AppleWebManagementQRCode(url: link.url, accessibilityText: "Setup QR code")
                    .frame(width: qrSide, height: qrSide)
                    .accessibilityIdentifier("setup.receive.qr")
                Button("Cancel") { center.endReceiving() }
                    .buttonStyle(.brandSecondary)
                    .accessibilityIdentifier("setup.receive.cancel")
            case .confirm(let sender, let count):
                Text("Import setup from \(sender)?")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Its sources and settings are added to this \(AppleSetupTransferDevice.noun).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("setup.receive.count.\(count)")
                HStack(spacing: 24) {
                    Button("Import") { Task { await center.importReceived(into: controller) } }
                        .buttonStyle(.brandPrimary)
                        .accessibilityIdentifier("setup.receive.import")
                    Button("Cancel") { center.endReceiving() }
                        .buttonStyle(.brandSecondary)
                        .accessibilityIdentifier("setup.receive.cancel")
                }
                #if DEBUG
                .task {
                    // A pause long enough for the end-to-end run's screenshot.
                    if UserDefaults.standard.bool(forKey: "OpenStreamDebugSetupAutoImport"),
                       (try? await Task.sleep(for: .seconds(4))) != nil {
                        // Unstructured, like the button: this view goes away mid-import.
                        Task { await center.importReceived(into: controller) }
                    }
                }
                #endif
            case .importing:
                ProgressView()
            case .imported(let count):
                Text("Setup imported · \(count) \(count == 1 ? "source" : "sources")")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("setup.receive.done")
                Button("Done") { center.endReceiving() }
                    .buttonStyle(.brandPrimary)
            case .failed(let message):
                Text(message)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("setup.receive.failed")
                HStack(spacing: 24) {
                    Button("Show New Code") { Task { await center.startReceiving() } }
                        .buttonStyle(.brandPrimary)
                    Button("Close") { center.endReceiving() }
                        .buttonStyle(.brandSecondary)
                }
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await center.startReceiving() }
        #if os(tvOS)
        .onExitCommand { center.endReceiving() }
        #endif
        .appleTraceScreen("setup.receive")
    }

    private var qrSide: CGFloat {
        #if os(tvOS)
        420
        #else
        280
        #endif
    }
}

/// The sending device, opened by a scanned QR code: "Send your setup to …?".
struct AppleSetupSendView: View {
    let link: AppleSetupTransferLink
    let controller: AppleConfigurationController?
    let close: () -> Void

    private enum Step: Equatable {
        case loading
        case confirm(String)
        case sending(String)
        case sent(String)
        case failed(String)
    }

    @State private var step: Step = .loading
    private let sender = AppleSetupTransferSender()

    var body: some View {
        VStack(spacing: 28) {
            switch step {
            case .loading, .sending:
                ProgressView()
            case .confirm(let name):
                Text("Send your setup to \(name)?")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                HStack(spacing: 20) {
                    Button("Cancel", action: close)
                        .buttonStyle(.brandSecondary)
                        .accessibilityIdentifier("setup.send.cancel")
                    Button("Send") { Task { await send(to: name) } }
                        .buttonStyle(.brandPrimary)
                        .accessibilityIdentifier("setup.send.confirm")
                }
                #if DEBUG
                .task {
                    if UserDefaults.standard.bool(forKey: "OpenStreamDebugSetupAutoSend"),
                       (try? await Task.sleep(for: .seconds(4))) != nil {
                        // Unstructured, like the button: this row goes away while sending.
                        Task { await send(to: name) }
                    }
                }
                #endif
            case .sent(let name):
                Text("Sent to \(name)")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("setup.send.done")
                Button("Done", action: close)
                    .buttonStyle(.brandPrimary)
            case .failed(let message):
                Text(message)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("setup.send.failed")
                Button("Close", action: close)
                    .buttonStyle(.brandSecondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.medium])
        .task { await loadName() }
        .appleTraceScreen("setup.send")
    }

    private func loadName() async {
        guard step == .loading else { return }
        do {
            let name = try await sender.receiverName(for: link)
            appleTrace("setup send: receiver answered")
            step = .confirm(name)
        } catch {
            appleTraceFailure("setup send: receiver unreachable")
            step = .failed(message(for: error))
        }
    }

    private func send(to name: String) async {
        guard case .confirm = step else { return }
        guard let controller else {
            step = .failed("Still starting. Try again in a moment.")
            return
        }
        step = .sending(name)
        appleTrace("setup send: sending")
        do {
            let payload = try controller.setupTransferPayload(sender: AppleSetupTransferDevice.name)
            try await sender.send(payload, to: link)
            appleTrace("setup send: delivered")
            step = .sent(name)
        } catch {
            appleTraceFailure("setup send: failed")
            step = .failed(message(for: error))
        }
    }

    private func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Couldn’t send the setup."
    }
}
