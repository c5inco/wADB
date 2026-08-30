import AppKit
import Network
import OSLog
import ServiceManagement

private final class WirelessDeviceMenuItemView: NSView {
    static let rowHeight: CGFloat = 24
    static let rowWidth: CGFloat = 280
    /// AppKit title inset after the menu-item state/checkmark column.
    static let titleLeadingInset: CGFloat = 22
    /// Matches where AppKit's key-equivalent column ends, measured against `⌘Q`.
    static let trailingInset: CGFloat = 16
    static let statusSpacing: CGFloat = 8
    static let iconSize: CGFloat = 16
    static let iconTitleSpacing: CGFloat = 4

    private let name: NSTextField
    private let status: NSImageView
    private let connection: NSTextField
    private let onActivate: (() -> Void)?

    init(device: WirelessDevice, onActivate: (() -> Void)? = nil) {
        self.onActivate = onActivate
        name = NSTextField(labelWithString: device.displayName)
        name.font = .menuFont(ofSize: 0)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = device.endpoint

        status = NSImageView()
        status.image = NSImage(
            systemSymbolName: Self.symbolName(for: device.state),
            accessibilityDescription: device.state.title
        )
        status.contentTintColor = Self.tintColor(for: device.state)

        connection = NSTextField(labelWithString: device.state.title)
        connection.font = .menuFont(ofSize: 0)
        connection.textColor = .secondaryLabelColor

        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
        autoresizingMask = [.width]
        addSubview(name)
        addSubview(status)
        addSubview(connection)
        if onActivate != nil {
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("\(device.displayName), \(device.state.title)")
        }
        layout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func mouseUp(with event: NSEvent) {
        guard let onActivate else {
            super.mouseUp(with: event)
            return
        }
        enclosingMenuItem?.menu?.cancelTracking()
        onActivate()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onActivate != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func layout() {
        super.layout()
        // `intrinsicContentSize` is fractional and rounds down often enough to
        // clip the final glyph, so give each label a whole point of slack.
        var connectionSize = connection.intrinsicContentSize
        connectionSize.width.round(.up)
        connectionSize.height.round(.up)
        let statusWidth = Self.iconSize + Self.iconTitleSpacing + connectionSize.width
        let statusX = bounds.width - Self.trailingInset - statusWidth
        status.frame = NSRect(
            x: statusX,
            y: ((bounds.height - Self.iconSize) / 2).rounded(.toNearestOrAwayFromZero),
            width: Self.iconSize,
            height: Self.iconSize
        )
        connection.frame = NSRect(
            x: statusX + Self.iconSize + Self.iconTitleSpacing,
            y: ((bounds.height - connectionSize.height) / 2).rounded(.toNearestOrAwayFromZero),
            width: connectionSize.width,
            height: connectionSize.height
        )

        var nameSize = name.intrinsicContentSize
        nameSize.height.round(.up)
        name.frame = NSRect(
            x: Self.titleLeadingInset,
            y: ((bounds.height - nameSize.height) / 2).rounded(.toNearestOrAwayFromZero),
            width: max(0, statusX - Self.statusSpacing - Self.titleLeadingInset),
            height: nameSize.height
        )
    }

    private static func symbolName(for state: WirelessDeviceState) -> String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .connecting: StatusItemSymbol.transitioning
        case .restartRecommended: "exclamationmark.circle.fill"
        case .needsPairing: "lock.slash"
        }
    }

    private static func tintColor(for state: WirelessDeviceState) -> NSColor {
        switch state {
        case .connected: .systemGreen
        case .connecting: .secondaryLabelColor
        case .restartRecommended: .systemOrange
        case .needsPairing: .systemOrange
        }
    }
}

#if DEBUG
private final class VerificationWindowController: NSWindowController {
    private let stateLabel = NSTextField(labelWithString: "Starting ADB…")
    private let devicesLabel = NSTextField(labelWithString: "No wireless devices")
    private let statusImageView = NSImageView()
    private let toggleButton: NSButton

    init(toggleItem: NSMenuItem) {
        // Exercise the status menu's exact target/action pair instead of a test-only path.
        toggleButton = NSButton(
            title: toggleItem.title,
            target: toggleItem.target,
            action: toggleItem.action
        )
        toggleButton.bezelStyle = .rounded
        toggleButton.identifier = NSUserInterfaceItemIdentifier("Verification.ToggleADB")

        stateLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        stateLabel.identifier = NSUserInterfaceItemIdentifier("Verification.ServerState")

        devicesLabel.font = .systemFont(ofSize: 13)
        devicesLabel.textColor = .secondaryLabelColor
        devicesLabel.maximumNumberOfLines = 0
        devicesLabel.lineBreakMode = .byWordWrapping
        devicesLabel.identifier = NSUserInterfaceItemIdentifier("Verification.Devices")

        statusImageView.imageScaling = .scaleProportionallyUpOrDown
        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        statusImageView.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let stateRow = NSStackView(views: [statusImageView, stateLabel])
        stateRow.orientation = .horizontal
        stateRow.alignment = .centerY
        stateRow.spacing = 10

        let stack = NSStackView(views: [stateRow, devicesLabel, toggleButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "wADB Verification"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(
        stateTitle: String,
        devices: [WirelessDevice],
        statusImage: NSImage?,
        toggleItem: NSMenuItem
    ) {
        stateLabel.stringValue = stateTitle
        statusImageView.image = statusImage
        toggleButton.title = toggleItem.title
        toggleButton.isEnabled = toggleItem.isEnabled
        devicesLabel.stringValue = devices.isEmpty
            ? "No wireless devices"
            : devices.map { "\($0.displayName) — \($0.state.title)" }.joined(separator: "\n")
    }
}
#endif

enum StatusItemSymbol {
    static let stopped = "cable.connector.slash"
    static let transitioning = "arrow.clockwise"
    static let running = "cable.connector.horizontal"
    static let unavailable = "exclamationmark.triangle"

    static let all = [stopped, transitioning, running, unavailable]
}

/// State modifiers overlaid on the bottom-right of the wireless debugging
/// glyph, so the menu bar keeps one recognizable icon across every state.
enum StatusItemBadge {
    static let imageSize: CGFloat = 18
    static let size: CGFloat = 12
    /// Extra canvas width past the glyph square, letting the badge sit further
    /// right than the glyph itself without shrinking either mark.
    static let overhang: CGFloat = 3
    /// Extra canvas height below the glyph square, letting the badge hang lower
    /// than the glyph. Kept small so the icon still fits the menu bar.
    static let drop: CGFloat = 2
    /// Clear ring punched behind the badge so it reads against the base glyph.
    static let gap: CGFloat = 0.5

    static let stopped = "xmark.circle.fill"
    static let transitioning = "ellipsis.circle.fill"
    static let unavailable = "exclamationmark.circle.fill"

    /// SF Symbols only ships filled number circles through 50.
    private static let highestNumbered = 50

    /// A single device reads as a checkmark; past that the count itself is the
    /// modifier, so the menu bar never needs a separate number label.
    static func connected(count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "checkmark.circle.fill"
        case 2...highestNumbered: "\(count).circle.fill"
        default: "plus.circle.fill"
        }
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    enum ADBServerState: Equatable {
        /// Stopped by the user from the menu. Deliberately not persisted:
        /// launching wADB is the intent to supervise, so Stop lasts only for
        /// this run rather than silently disabling the app on next launch.
        case stopped
        case starting
        case running
        case unavailable(String)

        var title: String {
            switch self {
            case .stopped: "ADB Stopped"
            case .starting: "Starting ADB…"
            case .running: "ADB Running"
            case let .unavailable(detail): "ADB Unavailable — \(detail)"
            }
        }

        var isStopped: Bool {
            if case .stopped = self { return true }
            return false
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var shouldAttemptStartOnWatchdogTick: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    private let logger = Logger(subsystem: "local.c5inco.wADB", category: "lifecycle")
    private let discovery = BonjourDiscovery()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "local.c5inco.wADB.path")
    private let endpointProbeQueue = DispatchQueue(label: "local.c5inco.wADB.endpoint-probe")

    private var didReceiveInitialPath = false
    private var statusItem: NSStatusItem!
    private var serverStateMenuItem: NSMenuItem!
    private var devicesHeaderMenuItem: NSMenuItem!
    private var devicesSeparatorMenuItem: NSMenuItem!
    private var deviceMenuItems: [NSMenuItem] = []
    private var startStopMenuItem: NSMenuItem!
    private var pairMenuItem: NSMenuItem!
    private var startAtLoginMenuItem: NSMenuItem!

    private var adb: ADBManager?
    private var adbInstallation: ADBInstallation?
    private var transports: [ADBTransport] = []
    private var services: [BonjourService] = []
    private var rememberedDevices = PairedDeviceStore.load()
    private var pairingCoordinator: PairingCoordinator?

    private var serverState: ADBServerState = .starting {
        didSet { updateMenuState() }
    }
    private var operationGeneration = UUID()
    private var watchdogTimer: Timer?
    private var isServerStartInFlight = false
    private var isRecoveryInFlight = false
    private var isExplicitRestartInFlight = false
    private var snapshotFailureCount = 0
    private var connectsInFlight = Set<String>()
    private var connectionRetries: [String: ADBConnectionRetryState] = [:]
    private var lastConnectionTargets: [String: ADBConnectionTarget] = [:]
    private var restartRecommendedDeviceIDs = Set<String>()
    private var reachabilityChecksInFlight = Set<String>()
    private var environmentRefreshWorkItem: DispatchWorkItem?
    private var duplicateEndpointsBeingRemoved = Set<String>()
    private var lastLoggedWirelessCount = -1
    private var lastLoggedServiceCounts = (-1, -1)
#if DEBUG
    private var verificationWindowController: VerificationWindowController?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        logger.info("wADB agent launched")
        ProcessInfo.processInfo.disableAutomaticTermination(
            "wADB supervises the standard ADB server."
        )
#if DEBUG
        let showsVerificationWindow = ProcessInfo.processInfo.arguments.contains(
            "--verification-window"
        )
        NSApp.setActivationPolicy(showsVerificationWindow ? .regular : .accessory)
        if captureUIStatesIfRequested() { return }
#else
        NSApp.setActivationPolicy(.accessory)
#endif
        configureStatusMenu()
#if DEBUG
        if showsVerificationWindow { showVerificationWindow() }
#endif
        configureDiscovery()
        configureWakeAndNetworkMonitoring()
        initializeADB()
    }

    func applicationWillTerminate(_ notification: Notification) {
        operationGeneration = UUID()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        environmentRefreshWorkItem?.cancel()
        pairingCoordinator?.cancel()
        adb?.stop()
        discovery.stop()
        pathMonitor.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // Quitting wADB intentionally leaves the shared ADB server running.
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenuState()
    }

    private func configureStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu(title: "wADB")
        menu.delegate = self

        serverStateMenuItem = NSMenuItem(title: "Starting ADB…", action: nil, keyEquivalent: "")
        serverStateMenuItem.isEnabled = false
        menu.addItem(serverStateMenuItem)

        devicesHeaderMenuItem = NSMenuItem(title: "Wireless Devices", action: nil, keyEquivalent: "")
        devicesHeaderMenuItem.isEnabled = false
        menu.addItem(devicesHeaderMenuItem)

        devicesSeparatorMenuItem = .separator()
        menu.addItem(devicesSeparatorMenuItem)

        startStopMenuItem = NSMenuItem(
            title: "Stop ADB",
            action: #selector(toggleADB),
            keyEquivalent: ""
        )
        startStopMenuItem.target = self
        menu.addItem(startStopMenuItem)

        pairMenuItem = NSMenuItem(
            title: "Pair new device…",
            action: #selector(pairNewDevice),
            keyEquivalent: ""
        )
        pairMenuItem.target = self
        menu.addItem(pairMenuItem)
        menu.addItem(.separator())

        startAtLoginMenuItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleStartAtLogin),
            keyEquivalent: ""
        )
        startAtLoginMenuItem.target = self
        menu.addItem(startAtLoginMenuItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "About wADB",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenuState()
    }

    private func configureDiscovery() {
        discovery.onServicesChanged = { [weak self] services in
            guard let self else { return }
            self.services = services
            let counts = (
                services.filter { $0.type == BonjourService.pairingType }.count,
                services.filter { $0.type == BonjourService.connectType }.count
            )
            if counts != self.lastLoggedServiceCounts {
                self.lastLoggedServiceCounts = counts
                self.logger.info(
                    "Bonjour resolved \(counts.0, privacy: .public) pairing and \(counts.1, privacy: .public) connect service(s)"
                )
            }
            self.pairingCoordinator?.update(services: services)
            self.reconcileWirelessConnections()
            self.updateMenuState()
        }
        discovery.onError = { [weak self] error in
            self?.logger.error(
                "Bonjour discovery error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func configureWakeAndNetworkMonitoring() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.pathQueue.async {
                let wasInitial = !self.didReceiveInitialPath
                self.didReceiveInitialPath = true
                guard !wasInitial, path.status == .satisfied else { return }
                DispatchQueue.main.async { self.refreshAfterEnvironmentChange() }
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func initializeADB() {
        do {
            adb = ADBManager(executableURL: try ADBManager.locateExecutable())
            startADB()
        } catch {
            serverState = .unavailable("adb not found")
            presentError(error, title: "Android Platform-Tools Required")
        }
    }

    private func startADB() {
        guard let adb else { return }
        operationGeneration = UUID()
        let generation = operationGeneration
        isServerStartInFlight = false
        isRecoveryInFlight = false
        isExplicitRestartInFlight = false
        snapshotFailureCount = 0
        connectsInFlight.removeAll()
        connectionRetries.removeAll()
        lastConnectionTargets.removeAll()
        restartRecommendedDeviceIDs.removeAll()
        reachabilityChecksInFlight.removeAll()
        environmentRefreshWorkItem?.cancel()
        environmentRefreshWorkItem = nil
        duplicateEndpointsBeingRemoved.removeAll()
        transports = []
        services = []
        serverState = .starting
        discovery.start()
        startWatchdog()
        attemptServerStart(using: adb, generation: generation)
    }

    @objc private func toggleADB() {
        if serverState.isStopped {
            startADB()
        } else {
            stopADB()
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// Hands the shared ADB server back to whoever else wants it (Android
    /// Studio, a terminal). Everything here is torn down for this run only.
    private func stopADB() {
        guard let adb else { return }
        logger.info("Stopping ADB at the user's request")
        operationGeneration = UUID()
        isServerStartInFlight = false
        isRecoveryInFlight = false
        isExplicitRestartInFlight = false
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        snapshotFailureCount = 0
        connectsInFlight.removeAll()
        connectionRetries.removeAll()
        lastConnectionTargets.removeAll()
        restartRecommendedDeviceIDs.removeAll()
        reachabilityChecksInFlight.removeAll()
        environmentRefreshWorkItem?.cancel()
        environmentRefreshWorkItem = nil
        duplicateEndpointsBeingRemoved.removeAll()
        pairingCoordinator?.cancel()
        pairingCoordinator = nil
        transports = []
        services = []
        adb.stopTracking()
        adb.cancelConnectionAttempt()
        adb.cancelPairingAttempt()
        adb.cancelOutstandingCommands()
        discovery.stop()
        serverState = .stopped
        adb.killServer { [weak self] result in
            guard case let .failure(error) = result else { return }
            self?.logger.error(
                "Could not stop ADB: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func restartADBForDevice(_ deviceID: String) {
        guard let adb,
              serverState.isRunning,
              restartRecommendedDeviceIDs.contains(deviceID),
              !isExplicitRestartInFlight else { return }
        let displayName = rememberedDevices.first {
            $0.serviceName == deviceID
        }?.displayName ?? deviceID
        logger.info(
            "Restarting standard ADB at the user's request for \(displayName, privacy: .public)"
        )
        isExplicitRestartInFlight = true
        operationGeneration = UUID()
        let generation = operationGeneration
        isServerStartInFlight = false
        isRecoveryInFlight = false
        snapshotFailureCount = 0
        transports = []
        connectsInFlight.removeAll()
        connectionRetries.removeAll()
        lastConnectionTargets.removeAll()
        restartRecommendedDeviceIDs.removeAll()
        reachabilityChecksInFlight.removeAll()
        duplicateEndpointsBeingRemoved.removeAll()
        pairingCoordinator?.cancel()
        pairingCoordinator = nil
        serverState = .starting
        adb.stopTracking()
        adb.cancelConnectionAttempt()
        adb.cancelPairingAttempt()
        adb.cancelOutstandingCommands()
        adb.killServer { [weak self, weak adb] result in
            DispatchQueue.main.async {
                guard let self,
                      let adb,
                      self.operationGeneration == generation else { return }
                if case let .failure(error) = result {
                    self.logger.error(
                        "Explicit ADB restart could not stop the old server: \(error.localizedDescription, privacy: .public)"
                    )
                }
                self.discovery.refresh()
                self.attemptServerStart(using: adb, generation: generation)
            }
        }
    }

    private func attemptServerStart(using adb: ADBManager, generation: UUID) {
        guard operationGeneration == generation, !isServerStartInFlight else { return }
        isServerStartInFlight = true
        serverState = .starting
        adb.prepare { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.operationGeneration == generation else { return }
                self.isServerStartInFlight = false
                self.isExplicitRestartInFlight = false
                switch result {
                case let .success(installation):
                    self.adbInstallation = installation
                    self.serverState = .running
                    self.logger.info(
                        "Supervising standard adb \(installation.version, privacy: .public) on localhost:5037"
                    )
                    adb.startTracking(
                        onUpdate: { [weak self] in self?.handleTransports($0) },
                        onStopped: { [weak self] error in
                            self?.handleTrackerStopped(error, generation: generation)
                        }
                    )
                    self.tick()
                case let .failure(error):
                    self.adbInstallation = nil
                    self.serverState = .unavailable(error.localizedDescription)
                    self.logger.error(
                        "ADB start failed: \(error.localizedDescription, privacy: .public)"
                    )
                    // No bespoke backoff here: the watchdog retries on its own tick.
                }
            }
        }
    }

    private func handleTrackerStopped(_ error: Error?, generation: UUID) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.handleTrackerStopped(error, generation: generation) }
            return
        }
        guard operationGeneration == generation else { return }
        if let error {
            logger.error("ADB observer stopped: \(error.localizedDescription, privacy: .public)")
        }
        recoverObserverOrServer(trigger: "device observer stopped", generation: generation)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(
            timeInterval: ADBWatchdogPolicy.tickInterval,
            repeats: true
        ) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = ADBWatchdogPolicy.tickInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    /// The single health check. It runs on a timer rather than off a
    /// `track-devices` edge, because that stream can stop delivering updates
    /// without erroring or closing — a silent stream and a healthy idle stream
    /// are indistinguishable, so anything edge-triggered stalls forever.
    private func tick() {
        guard let adb, !serverState.isStopped else { return }
        guard serverState.isRunning else {
            if serverState.shouldAttemptStartOnWatchdogTick {
                attemptServerStart(using: adb, generation: operationGeneration)
            }
            return
        }
        let generation = operationGeneration
        adb.snapshot { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.operationGeneration == generation else { return }
                switch snapshot {
                case let .success(transports):
                    self.snapshotFailureCount = 0
                    self.handleTransports(transports)
                case let .failure(error):
                    self.snapshotFailureCount += 1
                    self.logger.error(
                        "ADB snapshot failed (\(self.snapshotFailureCount, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                    )
                }
                if ADBWatchdogPolicy.shouldProbeServer(
                    snapshotFailures: self.snapshotFailureCount
                ) {
                    self.recoverObserverOrServer(
                        trigger: "\(self.snapshotFailureCount) consecutive snapshot failures",
                        generation: generation
                    )
                }
            }
        }
    }

    private var disconnectedRememberedDevices: [LastVerifiedDevice] {
        rememberedDevices.filter { remembered in
            !transports.contains {
                $0.state == .authorized
                    && WirelessDeviceResolver.matches(
                        $0,
                        rememberedDevice: remembered,
                        services: services
                    )
            }
        }
    }

    private func recoverObserverOrServer(trigger: String, generation: UUID) {
        guard let adb,
              operationGeneration == generation,
              serverState.isRunning,
              !isRecoveryInFlight else { return }
        isRecoveryInFlight = true
        let recoveryID = UUID().uuidString
        logger.info(
            "ADB recovery \(recoveryID, privacy: .public) probing localhost:5037; trigger=\(trigger, privacy: .public)"
        )
        adb.checkServerResponsive { [weak self, weak adb] responsive in
            DispatchQueue.main.async {
                guard let self,
                      let adb,
                      self.operationGeneration == generation,
                      !self.serverState.isStopped else { return }
                self.isRecoveryInFlight = false
                self.snapshotFailureCount = 0
                switch ADBWatchdogPolicy.recoveryAction(serverResponsive: responsive) {
                case .restartObserver:
                    self.logger.info(
                        "ADB recovery \(recoveryID, privacy: .public) found server responsive; restarting observer only"
                    )
                    adb.startTracking(
                        onUpdate: { [weak self] in self?.handleTransports($0) },
                        onStopped: { [weak self] error in
                            self?.handleTrackerStopped(error, generation: generation)
                        }
                    )
                case .startServer:
                    self.logger.error(
                        "ADB recovery \(recoveryID, privacy: .public) found server unavailable; requesting non-destructive start"
                    )
                    self.serverState = .unavailable("localhost:5037 did not respond")
                    self.attemptServerStart(using: adb, generation: generation)
                }
            }
        }
    }

    // MARK: - Transports

    private func handleTransports(_ transports: [ADBTransport]) {
        // ADBManager delivers tracker and snapshot callbacks on its own queue.
        // Everything below mutates AppDelegate state that the watchdog timer
        // also touches, so main is the only safe place to run it.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.handleTransports(transports) }
            return
        }
        self.transports = transports
        let connectedRememberedIDs = Set(rememberedDevices.compactMap { remembered in
            transports.contains {
                $0.state == .authorized
                    && WirelessDeviceResolver.matches(
                        $0,
                        rememberedDevice: remembered,
                        services: services
                    )
            } ? remembered.serviceName : nil
        })
        restartRecommendedDeviceIDs.subtract(connectedRememberedIDs)
        pairingCoordinator?.update(transports: transports)
        removeDuplicateExplicitConnections(from: transports)
        let connectedCount = wirelessDevices.filter { $0.state == .connected }.count
        if connectedCount != lastLoggedWirelessCount {
            lastLoggedWirelessCount = connectedCount
            logger.info(
                "Observed \(connectedCount, privacy: .public) connected wireless ADB device(s)"
            )
        }
        reconcileWirelessConnections()
        updateMenuState()
    }

    private func removeDuplicateExplicitConnections(from transports: [ADBTransport]) {
        guard serverState.isRunning, let adb else { return }
        let authorized = transports.filter { $0.state == .authorized }
        for service in services where service.type == BonjourService.connectType {
            let hasNativeTransport = authorized.contains {
                $0.connectServiceName == service.name
            }
            let hasExplicitTransport = authorized.contains {
                $0.serial == service.endpoint
            }
            guard hasNativeTransport,
                  hasExplicitTransport,
                  duplicateEndpointsBeingRemoved.insert(service.endpoint).inserted else {
                continue
            }
            adb.disconnect(from: service.endpoint) { [weak self, weak adb] result in
                guard let self else { return }
                if case let .success(processResult) = result, processResult.status != 0 {
                    self.logger.error(
                        "Could not remove duplicate explicit transport: \(processResult.combinedOutput, privacy: .public)"
                    )
                }
                adb?.snapshot { [weak self] snapshot in
                    guard let self else { return }
                    if case let .success(transports) = snapshot { self.handleTransports(transports) }
                    self.duplicateEndpointsBeingRemoved.remove(service.endpoint)
                }
            }
        }
    }

    /// Reconnect anything remembered that is not currently authorized. A
    /// refused endpoint backs off independently and can never affect server
    /// health. Genuine wireless-debugging port changes are attempted
    /// immediately; address-family churn keeps the existing backoff.
    private func reconcileWirelessConnections() {
        guard serverState.isRunning, pairingCoordinator == nil, let adb else { return }
        let disconnected = disconnectedRememberedDevices
        let disconnectedIDs = Set(disconnected.map(\.serviceName))
        let rememberedIDs = Set(rememberedDevices.map(\.serviceName))
        connectionRetries = connectionRetries.filter { disconnectedIDs.contains($0.key) }
        lastConnectionTargets = lastConnectionTargets.filter { rememberedIDs.contains($0.key) }
        guard connectsInFlight.isEmpty else { return }
        for device in disconnected {
            let previousTarget = lastConnectionTargets[device.serviceName]
            let target = ADBConnectionTargetResolver.resolve(
                device: device,
                services: services,
                previous: previousTarget
            )
            if previousTarget?.retryIdentity != target.retryIdentity {
                restartRecommendedDeviceIDs.remove(device.serviceName)
            }
            lastConnectionTargets[device.serviceName] = target
            guard !restartRecommendedDeviceIDs.contains(device.serviceName) else { continue }
            let endpoint = target.endpoint
            var retry = connectionRetries[device.serviceName] ?? ADBConnectionRetryState()
            guard retry.shouldAttempt(targetIdentity: target.retryIdentity, now: Date()) else {
                connectionRetries[device.serviceName] = retry
                continue
            }
            guard connectsInFlight.insert(endpoint).inserted else { continue }
            connectionRetries[device.serviceName] = retry
            let generation = operationGeneration
            logger.info(
                "Connecting \(device.displayName, privacy: .public) at \(endpoint, privacy: .public); attempt=\(retry.consecutiveFailures + 1, privacy: .public)"
            )
            adb.connect(to: endpoint) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.operationGeneration == generation else { return }
                    self.connectsInFlight.remove(endpoint)
                    switch result {
                    case let .success(processResult):
                        let output = processResult.combinedOutput
                        // Empty output means the attempt was cancelled by a
                        // state change, not that it failed.
                        guard !output.isEmpty else { return }
                        if ADBOutputParser.connectSucceeded(output) {
                            self.connectionRetries.removeValue(forKey: device.serviceName)
                        } else {
                            self.recordConnectionFailure(
                                output,
                                device: device,
                                target: target
                            )
                        }
                    case let .failure(error):
                        self.recordConnectionFailure(
                            error.localizedDescription,
                            device: device,
                            target: target
                        )
                    }
                }
            }
            return
        }
    }

    private func recordConnectionFailure(
        _ detail: String,
        device: LastVerifiedDevice,
        target: ADBConnectionTarget
    ) {
        var retry = connectionRetries[device.serviceName] ?? ADBConnectionRetryState()
        let delay = retry.recordFailure(targetIdentity: target.retryIdentity, now: Date())
        connectionRetries[device.serviceName] = retry
        logger.error(
            "Connect failed for \(device.displayName, privacy: .public) at \(target.endpoint, privacy: .public); retrying in \(Int(delay), privacy: .public)s: \(detail, privacy: .public)"
        )
        evaluateRestartRecommendation(
            failureDetail: detail,
            device: device,
            target: target,
            retry: retry
        )
    }

    private func evaluateRestartRecommendation(
        failureDetail: String,
        device: LastVerifiedDevice,
        target: ADBConnectionTarget,
        retry: ADBConnectionRetryState
    ) {
        let hasAdvertisedService = BonjourCorrelator.connectService(
            for: device,
            among: services
        ) != nil
        guard ADBDeviceRecoveryPolicy.shouldCheckEndpoint(
            consecutiveFailures: retry.consecutiveFailures,
            failureDetail: failureDetail,
            hasAdvertisedService: hasAdvertisedService
        ), !restartRecommendedDeviceIDs.contains(device.serviceName),
           reachabilityChecksInFlight.insert(device.serviceName).inserted else { return }
        let generation = operationGeneration
        checkEndpointReachable(target.endpoint) { [weak self] reachable in
            guard let self else { return }
            self.reachabilityChecksInFlight.remove(device.serviceName)
            guard reachable,
                  self.operationGeneration == generation,
                  self.serverState.isRunning,
                  self.connectionRetries[device.serviceName]?.targetIdentity
                    == target.retryIdentity else { return }
            self.restartRecommendedDeviceIDs.insert(device.serviceName)
            self.logger.error(
                "Standard ADB cannot reach \(device.displayName, privacy: .public) even though \(target.endpoint, privacy: .public) accepts TCP connections; recommending an explicit restart"
            )
            self.updateMenuState()
        }
    }

    private func checkEndpointReachable(
        _ endpoint: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard let parsed = ADBNetworkEndpoint.parse(endpoint),
              let port = NWEndpoint.Port(rawValue: parsed.port) else {
            completion(false)
            return
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(parsed.host),
            port: port,
            using: .tcp
        )
        endpointProbeQueue.async {
            var completed = false
            func finish(_ reachable: Bool) {
                guard !completed else { return }
                completed = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                DispatchQueue.main.async { completion(reachable) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: self.endpointProbeQueue)
            self.endpointProbeQueue.asyncAfter(deadline: .now() + 1) {
                finish(false)
            }
        }
    }

    @objc private func pairNewDevice() {
        guard serverState.isRunning, pairingCoordinator == nil, let adb else { return }
        let coordinator = PairingCoordinator(adb: adb) { [weak self] result in
            guard let self else { return }
            self.pairingCoordinator = nil
            guard self.serverState.isRunning else {
                self.updateMenuState()
                return
            }
            if case let .success(device) = result {
                PairedDeviceStore.upsert(device)
                self.rememberedDevices = PairedDeviceStore.load()
                adb.snapshot { [weak self] snapshot in
                    if case let .success(transports) = snapshot {
                        self?.handleTransports(transports)
                    }
                }
            }
            self.reconcileWirelessConnections()
            self.updateMenuState()
        }
        pairingCoordinator = coordinator
        updateMenuState()
        discovery.start { [weak self, weak coordinator] in
            guard let self, let coordinator, self.pairingCoordinator === coordinator else { return }
            coordinator.start(currentServices: self.services)
            coordinator.update(transports: self.transports)
        }
    }

    @objc private func toggleStartAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                let alert = NSAlert()
                alert.messageText = "Login Item Approval Required"
                alert.informativeText = "Allow wADB in System Settings → General → Login Items."
                alert.addButton(withTitle: "Open Login Items")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate()
                if alert.runModal() == .alertFirstButtonReturn {
                    SMAppService.openSystemSettingsLoginItems()
                }
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                throw ADBManagerError.commandFailed(
                    "The login item state is not supported by this macOS version."
                )
            }
        } catch {
            presentError(error, title: "Start at Login Could Not Be Changed")
        }
        updateMenuState()
    }

    @objc private func didWake() {
        refreshAfterEnvironmentChange()
    }

    private func refreshAfterEnvironmentChange() {
        guard adb != nil, !serverState.isStopped else { return }
        environmentRefreshWorkItem?.cancel()
        let generation = operationGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.operationGeneration == generation,
                  self.adb != nil,
                  !self.serverState.isStopped else { return }
            self.environmentRefreshWorkItem = nil
            self.logger.info("Refreshing discovery after wake or network change")
            self.discovery.refresh()
            self.tick()
        }
        environmentRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private var wirelessDevices: [WirelessDevice] {
        guard serverState.isRunning else { return [] }
        return WirelessDeviceResolver.resolve(
            transports: transports,
            services: services,
            rememberedDevices: rememberedDevices
        ).map { device in
            guard device.state == .connecting,
                  restartRecommendedDeviceIDs.contains(device.id) else { return device }
            return WirelessDevice(
                id: device.id,
                displayName: device.displayName,
                endpoint: device.endpoint,
                state: .restartRecommended
            )
        }
    }

    private func updateMenuState() {
        guard statusItem != nil,
              let statusButton = statusItem.button,
              let menu = statusItem.menu else { return }

        let devices = wirelessDevices
        let connectedCount = devices.filter { $0.state == .connected }.count
        let isPairing = pairingCoordinator != nil
        serverStateMenuItem.title = isPairing ? "Pairing…" : serverState.title
        serverStateMenuItem.isHidden = serverState.isRunning && !isPairing

        for item in deviceMenuItems { menu.removeItem(item) }
        deviceMenuItems.removeAll()

        let showDevices = serverState.isRunning
        devicesHeaderMenuItem.isHidden = !showDevices
        devicesSeparatorMenuItem.isHidden = !showDevices
        if showDevices {
            var insertionIndex = menu.index(of: devicesHeaderMenuItem) + 1
            if devices.isEmpty {
                let empty = NSMenuItem(
                    title: "No wireless devices",
                    action: nil,
                    keyEquivalent: ""
                )
                empty.isEnabled = false
                menu.insertItem(empty, at: insertionIndex)
                deviceMenuItems.append(empty)
            } else {
                for device in devices {
                    let item = NSMenuItem()
                    item.title = "\(device.displayName), \(device.state.title)"
                    item.toolTip = device.endpoint
                    let onActivate: (() -> Void)? = device.state == .restartRecommended
                        ? { [weak self] in self?.restartADBForDevice(device.id) }
                        : nil
                    item.view = WirelessDeviceMenuItemView(
                        device: device,
                        onActivate: onActivate
                    )
                    menu.insertItem(item, at: insertionIndex)
                    deviceMenuItems.append(item)
                    insertionIndex += 1
                }
            }
        }

        startStopMenuItem.title = serverState.isStopped ? "Start ADB" : "Stop ADB"
        startStopMenuItem.isEnabled = adb != nil
        pairMenuItem.isHidden = !showDevices
        pairMenuItem.isEnabled = showDevices && pairingCoordinator == nil
        startAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        statusButton.image = statusImage(connectedCount: connectedCount)
        statusButton.toolTip = statusToolTip(devices: devices)
        statusButton.title = ""
        statusButton.imagePosition = .imageOnly
#if DEBUG
        verificationWindowController?.update(
            stateTitle: serverState.title,
            devices: devices,
            statusImage: statusButton.image,
            toggleItem: startStopMenuItem
        )
#endif
    }

    private func statusImage(connectedCount: Int) -> NSImage? {
        guard let base = NSImage(named: "StatusWirelessDebugging") else {
            let symbol: String
            switch serverState {
            case .stopped: symbol = StatusItemSymbol.stopped
            case .starting: symbol = StatusItemSymbol.transitioning
            case .running: symbol = StatusItemSymbol.running
            case .unavailable: symbol = StatusItemSymbol.unavailable
            }
            return symbolStatusImage(symbol, accessibilityDescription: serverState.title)
        }
        return Self.badgedStatusImage(
            base: base,
            badgeSymbol: statusBadgeSymbol(connectedCount: connectedCount),
            accessibilityDescription: statusAccessibilityLabel(connectedCount: connectedCount)
        )
    }

    private func statusAccessibilityLabel(connectedCount: Int) -> String {
        guard serverState.isRunning, connectedCount > 0 else { return serverState.title }
        let devices = connectedCount == 1 ? "1 device" : "\(connectedCount) devices"
        return "\(serverState.title) — \(devices) connected"
    }

    /// A running server with no devices reads as the bare glyph; every other
    /// state adds a modifier.
    private func statusBadgeSymbol(connectedCount: Int) -> String? {
        switch serverState {
        case .stopped: StatusItemBadge.stopped
        case .starting: StatusItemBadge.transitioning
        case .unavailable: StatusItemBadge.unavailable
        case .running: StatusItemBadge.connected(count: connectedCount)
        }
    }

    private static func badgedStatusImage(
        base: NSImage,
        badgeSymbol: String?,
        accessibilityDescription: String
    ) -> NSImage {
        let side = StatusItemBadge.imageSize
        let badge = badgeSymbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: StatusItemBadge.size, weight: .bold))
        }
        let canvas = NSSize(
            width: side + StatusItemBadge.overhang,
            height: side + StatusItemBadge.drop
        )
        let image = NSImage(size: canvas, flipped: false) { rect in
            let glyphRect = NSRect(x: rect.minX, y: rect.maxY - side, width: side, height: side)
            base.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
            guard let badge, let context = NSGraphicsContext.current else { return true }
            let badgeRect = NSRect(
                x: rect.maxX - StatusItemBadge.size,
                y: rect.minY,
                width: StatusItemBadge.size,
                height: StatusItemBadge.size
            )
            // Punch the badge's footprint out of the glyph so the two marks
            // never overlap into mush at menu bar size.
            context.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(
                ovalIn: badgeRect.insetBy(dx: -StatusItemBadge.gap, dy: -StatusItemBadge.gap)
            ).fill()
            context.compositingOperation = .sourceOver
            badge.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private func symbolStatusImage(_ name: String, accessibilityDescription: String) -> NSImage? {
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityDescription
        ) else { return nil }
        let configured = image.withSymbolConfiguration(
            .init(pointSize: 14, weight: .regular)
        ) ?? image
        configured.isTemplate = true
        return configured
    }

    private func statusToolTip(devices: [WirelessDevice]) -> String {
        guard serverState.isRunning else { return serverState.title }
        if devices.isEmpty { return "ADB Running — No wireless devices" }
        return devices.map { "\($0.displayName) — \($0.state.title)" }
            .joined(separator: "\n")
    }

#if DEBUG
    private func showVerificationWindow() {
        let controller = VerificationWindowController(toggleItem: startStopMenuItem)
        verificationWindowController = controller
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        updateMenuState()
    }

    private func captureUIStatesIfRequested() -> Bool {
        let prefix = "--capture-ui-states="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix(prefix)
        }) else { return false }
        let directory = URL(fileURLWithPath: String(argument.dropFirst(prefix.count)))
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let remembered = PairedDeviceStore.load().first
            let connected = WirelessDevice(
                id: remembered?.serviceName ?? "adb-preview",
                displayName: remembered?.displayName ?? "Example Phone",
                endpoint: remembered?.endpoint ?? "192.0.2.10:37001",
                state: .connected
            )
            try captureMenuPreview(
                title: nil,
                devices: [connected],
                showsPairing: true,
                to: directory.appendingPathComponent("wadb-running-connected.png")
            )
            let restartRecommended = WirelessDevice(
                id: connected.id,
                displayName: connected.displayName,
                endpoint: connected.endpoint,
                state: .restartRecommended
            )
            try captureMenuPreview(
                title: nil,
                devices: [restartRecommended],
                showsPairing: true,
                to: directory.appendingPathComponent("wadb-restart-recommended.png")
            )
            try captureMenuPreview(
                title: nil,
                devices: [],
                showsPairing: true,
                to: directory.appendingPathComponent("wadb-running-empty.png")
            )
            try captureMenuPreview(
                title: "Starting ADB…",
                devices: nil,
                showsPairing: false,
                to: directory.appendingPathComponent("wadb-starting.png")
            )

            let pairing = PairingWindowController()
            try pairing.show(
                qrPayload: Data("WIFI:T:ADB;S:studio-Preview123;P:Preview123;;".utf8)
            )
            if let contentView = pairing.window?.contentView {
                try capture(view: contentView, to: directory.appendingPathComponent(
                    "wadb-qr-pairing.png"
                ))
            }
            pairing.closeWithoutCancelling()
        } catch {
            logger.error("UI state capture failed: \(error.localizedDescription, privacy: .public)")
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    private func captureMenuPreview(
        title: String?,
        devices: [WirelessDevice]?,
        showsPairing: Bool,
        to url: URL
    ) throws {
        let width: CGFloat = 300
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)

        if let title {
            stack.addArrangedSubview(menuPreviewLabel(title, width: width, secondary: true))
        }
        if let devices {
            stack.addArrangedSubview(
                menuPreviewLabel("Wireless Devices", width: width, secondary: true)
            )
            if devices.isEmpty {
                stack.addArrangedSubview(
                    menuPreviewLabel("No wireless devices", width: width, secondary: true)
                )
            } else {
                for device in devices {
                    let row = WirelessDeviceMenuItemView(device: device)
                    row.translatesAutoresizingMaskIntoConstraints = false
                    row.widthAnchor.constraint(equalToConstant: width).isActive = true
                    row.heightAnchor.constraint(
                        equalToConstant: WirelessDeviceMenuItemView.rowHeight
                    ).isActive = true
                    stack.addArrangedSubview(row)
                }
            }
            stack.addArrangedSubview(menuPreviewSeparator(width: width))
        }
        if showsPairing {
            stack.addArrangedSubview(menuPreviewLabel("Pair new device…", width: width))
        }
        stack.addArrangedSubview(menuPreviewSeparator(width: width))
        stack.addArrangedSubview(menuPreviewLabel("Start at Login", width: width))
        stack.addArrangedSubview(menuPreviewSeparator(width: width))
        stack.addArrangedSubview(menuPreviewLabel("About wADB", width: width))
        stack.addArrangedSubview(menuPreviewLabel("Quit", width: width))

        stack.translatesAutoresizingMaskIntoConstraints = false
        let fitting = stack.fittingSize
        let effect = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: width, height: max(fitting.height, 100))
        )
        effect.material = .menu
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        try capture(view: effect, to: url)
    }

    /// Wraps a menu label in a full-width row so preview insets match a real
    /// `NSMenu`, where every title starts after the state (checkmark) column.
    private func menuPreviewLabel(
        _ text: String,
        width: CGFloat,
        secondary: Bool = false
    ) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .menuFont(ofSize: 0)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: width),
            row.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(
                equalTo: row.leadingAnchor,
                constant: WirelessDeviceMenuItemView.titleLeadingInset
            ),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func menuPreviewSeparator(width: CGFloat) -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(separator)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: width),
            row.heightAnchor.constraint(equalTo: separator.heightAnchor),
            separator.leadingAnchor.constraint(
                equalTo: row.leadingAnchor,
                constant: WirelessDeviceMenuItemView.trailingInset
            ),
            separator.trailingAnchor.constraint(
                equalTo: row.trailingAnchor,
                constant: -WirelessDeviceMenuItemView.trailingInset
            ),
            separator.topAnchor.constraint(equalTo: row.topAnchor),
        ])
        return row
    }

    private func capture(view: NSView, to url: URL) throws {
        let size = view.bounds.width > 0 && view.bounds.height > 0
            ? view.bounds.size
            : view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        var captureWindow: NSWindow?
        if view.window == nil {
            let window = NSWindow(
                contentRect: view.bounds,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            captureWindow = window
        } else {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ADBManagerError.commandFailed("Could not allocate a UI screenshot bitmap.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ADBManagerError.commandFailed("Could not encode a UI screenshot.")
        }
        try data.write(to: url)
        captureWindow?.contentView = nil
    }
#endif

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        NSApp.activate()
        alert.runModal()
    }
}
