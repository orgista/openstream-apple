#if DEBUG && os(iOS)
import SwiftUI
import UIKit

/// Exercises the real phone hierarchy at a larger window size; captures include the entire canvas.
public struct AppleDebugLayoutHost<Canvas: View>: View {
    let content: Canvas
    @Environment(\.scenePhase) private var scenePhase

    /// "width,height", or "width,height,compact" for a compact-width window (an iPad split).
    private var request: String { UserDefaults.standard.string(forKey: "OpenStreamDebugLayoutSize") ?? "" }

    private var requestedSize: CGSize? {
        let values = request.split(separator: ",").compactMap { Double($0) }
        guard values.count == 2, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return CGSize(width: values[0], height: values[1])
    }

    public var body: some View {
        if let size = requestedSize {
            AppleDebugLayoutCanvas(content: content.environment(\.scenePhase, scenePhase)
                .tint(.white).preferredColorScheme(.dark)
                .statusBarHidden().symbolEffectsRemoved()
                .transaction { $0.animation = nil; $0.disablesAnimations = true }, size: size,
                isCompactWidth: request.hasSuffix(",compact"))
        } else {
            content
        }
    }
}

public extension View {
    func appleDebugLayoutHost() -> some View {
        AppleDebugLayoutHost(content: self)
    }
}

private struct AppleDebugLayoutCanvas<Canvas: View>: UIViewControllerRepresentable {
    let content: Canvas
    let size: CGSize
    let isCompactWidth: Bool

    func makeUIViewController(context: Context) -> AppleDebugLayoutController<Canvas> {
        AppleDebugLayoutController(content: content, size: size, isCompactWidth: isCompactWidth)
    }

    func updateUIViewController(_ controller: AppleDebugLayoutController<Canvas>, context: Context) {
        controller.host.rootView = content
    }

    static func dismantleUIViewController(_ controller: AppleDebugLayoutController<Canvas>, coordinator: ()) {
        controller.closeCanvas()
    }
}

/// UIKit navigation and lazy containers must read the simulated window's bounds and safe area.
private final class AppleDebugCanvasWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

private final class AppleDebugLayoutController<Canvas: View>: UIViewController {
    let host: UIHostingController<Canvas>
    private let expandedSize: CGSize
    private let isCompactWidth: Bool
    private var canvasSize: CGSize
    private var isFolded = false
    private var isRotated = false
    private var captureIndex = 0
    private let captureButton = UIButton(type: .system)
    private var canvasWindow: AppleDebugCanvasWindow?
    private weak var originalWindow: UIWindow?

    init(content: Canvas, size: CGSize, isCompactWidth: Bool) {
        host = UIHostingController(rootView: content)
        expandedSize = size
        self.isCompactWidth = isCompactWidth
        canvasSize = size
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let fold = button("Fold", identifier: "debug.layout.fold") { [weak self] in
            self?.isFolded.toggle()
            self?.resizeCanvas()
        }
        let rotate = button("Rotate", identifier: "debug.layout.rotate") { [weak self] in
            self?.isRotated.toggle()
            self?.resizeCanvas()
        }
        captureButton.setTitle("Capture", for: .normal)
        captureButton.accessibilityIdentifier = "debug.layout.capture"
        captureButton.addAction(UIAction { [weak self] _ in self?.capture() }, for: .touchUpInside)
        let tools = UIStackView(arrangedSubviews: [fold, rotate, captureButton])
        tools.spacing = AppleDesignTokens.spacingSmall
        tools.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tools)
        NSLayoutConstraint.activate([
            tools.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tools.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            tools.heightAnchor.constraint(equalToConstant: AppleDesignTokens.minimumActionSize),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard canvasWindow == nil, let original = view.window, let scene = original.windowScene else { return }
        originalWindow = original
        let window = AppleDebugCanvasWindow(windowScene: scene)
        canvasWindow = window
        window.rootViewController = host
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.backgroundColor = .black
        resizeCanvas()
        window.makeKeyAndVisible()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        resizeWindow()
    }

    func closeCanvas() {
        let wasKey = canvasWindow?.isKeyWindow == true
        canvasWindow?.isHidden = true
        canvasWindow?.rootViewController = nil
        canvasWindow = nil
        if wasKey { originalWindow?.makeKeyAndVisible() }
    }

    private func button(_ title: String, identifier: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func resizeCanvas() {
        canvasSize = isFolded ? CGSize(width: 466, height: 678)
            : (isRotated ? CGSize(width: expandedSize.height, height: expandedSize.width) : expandedSize)
        canvasWindow?.traitOverrides.horizontalSizeClass = isFolded || isCompactWidth ? .compact : .regular
        captureButton.accessibilityValue = canvasDescription
        resizeWindow()
    }

    private func resizeWindow() {
        guard let window = canvasWindow, let original = originalWindow else { return }
        var available = original.bounds.inset(by: original.safeAreaInsets)
        available.size.height -= AppleDesignTokens.minimumActionSize + AppleDesignTokens.spacingSmall
        let scale = min(available.width / canvasSize.width, available.height / canvasSize.height)
        let bounds = CGRect(origin: .zero, size: canvasSize)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let center = CGPoint(x: available.minX + canvasSize.width * scale / 2,
                             y: available.minY + canvasSize.height * scale / 2)
        UIView.performWithoutAnimation {
            if window.bounds != bounds { window.bounds = bounds }
            if window.transform != transform { window.transform = transform }
            if window.center != center { window.center = center }
            window.layoutIfNeeded()
        }
    }

    private var canvasDescription: String {
        let idiom = host.traitCollection.userInterfaceIdiom == .phone ? "phone" : "pad"
        return "\(Int(canvasSize.width))x\(Int(canvasSize.height)) \(idiom) \(isFolded || isCompactWidth ? "compact" : "regular")"
    }

    private func splitGeometry(in controller: UIViewController) -> [String] {
        let children = controller.children.flatMap { splitGeometry(in: $0) }
        guard let split = controller as? UISplitViewController, let view = split.viewIfLoaded else { return children }
        let secondaryMinimum: String
        if #available(iOS 26, *) {
            secondaryMinimum = "\(split.minimumSecondaryColumnWidth)"
        } else {
            secondaryMinimum = "unavailable"
        }
        return ["split bounds=\(view.bounds.size) safe=\(view.safeAreaInsets) "
            + "mode=\(split.displayMode.rawValue) behavior=\(split.splitBehavior.rawValue) "
            + "primary=\(split.primaryColumnWidth) min=\(split.minimumPrimaryColumnWidth) "
            + "secondaryMin=\(secondaryMinimum)"] + children
    }

    private func capture() {
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var rendered = false
        let image = UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: canvasSize))
            rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        guard rendered, let data = image.pngData(),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            captureButton.accessibilityValue = "Capture failed"
            return
        }
        let name = "duo-layout-\(captureIndex).png"
        do {
            try data.write(to: caches.appendingPathComponent(name), options: .atomic)
            captureButton.accessibilityValue = "\(name) \(canvasDescription) " + splitGeometry(in: host).joined(separator: "; ")
            captureIndex += 1
        } catch {
            captureButton.accessibilityValue = "Capture failed"
        }
    }
}
#endif
