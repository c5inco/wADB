import Darwin
import Foundation

struct ADBInstallation: Equatable {
    let executableURL: URL
    let version: String
}

enum ADBServerStartOutcome: Equatable {
    case alreadyResponsive
    case started(exitStatus: Int32)
    case competingStarterWon(exitStatus: Int32?)
}

struct ADBPreparation: Equatable {
    let installation: ADBInstallation
    let serverStartOutcome: ADBServerStartOutcome
}

struct ADBProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum ADBManagerError: LocalizedError {
    case missingExecutable
    case invalidExecutable(String)
    case launchFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            "Android SDK Platform-Tools were not found. Install Platform-Tools from Android Studio's SDK Manager, then relaunch wADB."
        case let .invalidExecutable(detail):
            "The selected adb executable is not usable. \(detail)"
        case let .launchFailed(detail):
            "adb could not be launched. \(detail)"
        case let .commandFailed(detail):
            detail
        }
    }
}

final class ADBManager {
    typealias ResultHandler = (Result<ADBProcessResult, Error>) -> Void

    private let executableURL: URL
    private let serverProbe: () -> Bool
    private let postStartProbeDelay: TimeInterval
    private let queue = DispatchQueue(label: "local.c5inco.wADB.adb")
    private var trackProcess: Process?
    private var trackOutputHandle: FileHandle?
    private var connectProcess: Process?
    private var pairProcess: Process?
    private var ordinaryProcesses: [ObjectIdentifier: Process] = [:]
    private var trackParser = TrackDevicesFrameParser()
    private var trackerGeneration = UUID()
    private var transportHandler: (([ADBTransport]) -> Void)?
    private var trackerStoppedHandler: ((Error?) -> Void)?

    init(
        executableURL: URL,
        serverProbe: @escaping () -> Bool = { ADBManager.standardServerIsResponsive() },
        postStartProbeDelay: TimeInterval = 0.25
    ) {
        self.executableURL = executableURL
        self.serverProbe = serverProbe
        self.postStartProbeDelay = postStartProbeDelay
    }

    static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        var candidates = [
            homeDirectory.appendingPathComponent("Library/Android/sdk/platform-tools/adb"),
            homeDirectory.appendingPathComponent("Android/Sdk/platform-tools/adb"),
        ]
        for variable in ["ANDROID_SDK_ROOT", "ANDROID_HOME"] {
            if let root = environment[variable], !root.isEmpty {
                candidates.append(URL(fileURLWithPath: root).appendingPathComponent("platform-tools/adb"))
            }
        }
        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/adb"),
            URL(fileURLWithPath: "/usr/local/bin/adb"),
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("adb")
            }
        }
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.path).inserted {
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw ADBManagerError.missingExecutable
    }

    static func standardServerEnvironment(
        from environment: [String: String]
    ) -> [String: String] {
        var environment = environment
        // ADB_SERVER_SOCKET makes `adb start-server` treat even localhost as a
        // remote server, so it cannot recover the standard daemon after a kill.
        environment.removeValue(forKey: "ADB_SERVER_SOCKET")
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_PORT")
        environment.removeValue(forKey: "ANDROID_ADB_SERVER_ADDRESS")
        environment.removeValue(forKey: "ADB_VENDOR_KEYS")
        return environment
    }

    func prepare(completion: @escaping (Result<ADBPreparation, Error>) -> Void) {
        run(arguments: ["version"]) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(versionResult):
                guard versionResult.status == 0,
                      versionResult.combinedOutput.contains("Android Debug Bridge version"),
                      let version = Self.extractVersion(versionResult.combinedOutput) else {
                    let detail = versionResult.combinedOutput.isEmpty
                        ? "No output from \(self.executableURL.path)."
                        : versionResult.combinedOutput
                    completion(.failure(ADBManagerError.invalidExecutable(detail)))
                    return
                }
                self.startServer(version: version, completion: completion)
            }
        }
    }

    func killServer(completion: @escaping ResultHandler) {
        run(arguments: ["kill-server"]) { result in
            completion(result.flatMap { processResult in
                guard processResult.status == 0 else {
                    let detail = processResult.combinedOutput.isEmpty
                        ? "The standard ADB server could not be stopped."
                        : processResult.combinedOutput
                    return .failure(ADBManagerError.commandFailed(detail))
                }
                return .success(processResult)
            })
        }
    }

    func snapshot(completion: @escaping (Result<[ADBTransport], Error>) -> Void) {
        run(arguments: ["devices", "-l"]) { result in
            completion(result.flatMap { processResult in
                guard processResult.status == 0 else {
                    return .failure(ADBManagerError.commandFailed(processResult.combinedOutput))
                }
                return .success(ADBOutputParser.parseDeviceList(processResult.standardOutput))
            })
        }
    }

    func checkServerResponsive(completion: @escaping (Bool) -> Void) {
        probeServer(completion: completion)
    }

    func connect(to endpoint: String, completion: @escaping ResultHandler) {
        queue.async {
            self.connectProcess?.terminate()
            self.launchLocked(
                arguments: ["connect", endpoint],
                input: nil,
                kind: .connect,
                completion: completion
            )
        }
    }

    func disconnect(from endpoint: String, completion: @escaping ResultHandler) {
        run(arguments: ["disconnect", endpoint], completion: completion)
    }

    func pair(to endpoint: String, passwordInput: NSMutableData, completion: @escaping ResultHandler) {
        queue.async {
            self.pairProcess?.terminate()
            self.launchLocked(
                arguments: ["pair", endpoint],
                input: passwordInput,
                kind: .pair,
                completion: completion
            )
        }
    }

    func cancelConnectionAttempt() {
        queue.async { self.connectProcess?.terminate() }
    }

    func cancelPairingAttempt() {
        queue.async { self.pairProcess?.terminate() }
    }

    func cancelOutstandingCommands() {
        queue.async { self.cancelOrdinaryProcessesLocked() }
    }

    func startTracking(
        onUpdate: @escaping ([ADBTransport]) -> Void,
        onStopped: @escaping (Error?) -> Void
    ) {
        queue.async {
            self.stopTrackerLocked()
            self.transportHandler = onUpdate
            self.trackerStoppedHandler = onStopped
            self.startTrackerLocked()
        }
    }

    func stopTracking() {
        queue.async { self.stopTrackerLocked() }
    }

    /// Stops wADB-owned child processes. The shared ADB server is deliberately
    /// left running; only the explicit Stop ADB action calls `killServer`.
    func stop() {
        queue.sync {
            stopTrackerLocked()
            connectProcess?.terminate()
            connectProcess = nil
            pairProcess?.terminate()
            pairProcess = nil
            cancelOrdinaryProcessesLocked()
        }
    }

    private func startServer(
        version: String,
        completion: @escaping (Result<ADBPreparation, Error>) -> Void
    ) {
        probeServer { [weak self] serverIsResponsive in
            guard let self else { return }
            guard !serverIsResponsive else {
                completion(.success(ADBPreparation(
                    installation: ADBInstallation(
                        executableURL: self.executableURL,
                        version: version
                    ),
                    serverStartOutcome: .alreadyResponsive
                )))
                return
            }
            self.run(arguments: ["start-server"]) { [weak self] result in
                guard let self else { return }
                if case let .success(processResult) = result, processResult.status == 0 {
                    completion(.success(ADBPreparation(
                        installation: ADBInstallation(
                            executableURL: self.executableURL,
                            version: version
                        ),
                        serverStartOutcome: .started(exitStatus: processResult.status)
                    )))
                    return
                }
                // Another ADB client can win the localhost:5037 race while this
                // starter reports "Address already in use" or "didn't ACK".
                self.probeServer(after: self.postStartProbeDelay) { [weak self] responsive in
                    guard let self else { return }
                    if responsive {
                        let exitStatus: Int32?
                        switch result {
                        case let .success(processResult):
                            exitStatus = processResult.status
                        case .failure:
                            exitStatus = nil
                        }
                        completion(.success(ADBPreparation(
                            installation: ADBInstallation(
                                executableURL: self.executableURL,
                                version: version
                            ),
                            serverStartOutcome: .competingStarterWon(exitStatus: exitStatus)
                        )))
                    } else {
                        completion(self.serverStartFailure(from: result))
                    }
                }
            }
        }
    }

    private func probeServer(
        after delay: TimeInterval = 0,
        completion: @escaping (Bool) -> Void
    ) {
        queue.asyncAfter(deadline: .now() + delay) {
            let responsive = self.serverProbe()
            DispatchQueue.main.async { completion(responsive) }
        }
    }

    private func serverStartFailure(
        from result: Result<ADBProcessResult, Error>
    ) -> Result<ADBPreparation, Error> {
        switch result {
        case let .failure(error):
            .failure(error)
        case let .success(processResult):
            .failure(ADBManagerError.commandFailed(
                processResult.combinedOutput.isEmpty
                    ? "The standard ADB server could not be started."
                    : processResult.combinedOutput
            ))
        }
    }

    private enum ProcessKind { case ordinary, connect, pair }

    private func run(arguments: [String], completion: @escaping ResultHandler) {
        queue.async {
            self.launchLocked(
                arguments: arguments,
                input: nil,
                kind: .ordinary,
                completion: completion
            )
        }
    }

    private func launchLocked(
        arguments: [String],
        input: NSMutableData?,
        kind: ProcessKind,
        completion: @escaping ResultHandler
    ) {
        let process = configuredProcess(arguments: arguments)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var inputPipe: Pipe?
        if input != nil {
            inputPipe = Pipe()
            process.standardInput = inputPipe
        }
        process.terminationHandler = { [weak self] finished in
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
            self?.queue.async {
                if kind == .ordinary {
                    self?.ordinaryProcesses.removeValue(forKey: ObjectIdentifier(finished))
                }
                if kind == .connect, self?.connectProcess === finished { self?.connectProcess = nil }
                if kind == .pair, self?.pairProcess === finished { self?.pairProcess = nil }
                let result = ADBProcessResult(
                    status: finished.terminationStatus,
                    standardOutput: String(decoding: output, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    standardError: String(decoding: error, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
                DispatchQueue.main.async { completion(.success(result)) }
            }
        }
        do {
            try process.run()
            if kind == .ordinary {
                ordinaryProcesses[ObjectIdentifier(process)] = process
            }
            if kind == .connect { connectProcess = process }
            if kind == .pair { pairProcess = process }
            if let secretInput = input, let inputPipe {
                Self.write(secretInput, to: inputPipe.fileHandleForWriting.fileDescriptor)
                inputPipe.fileHandleForWriting.closeFile()
                secretInput.resetBytes(in: NSRange(location: 0, length: secretInput.length))
            }
        } catch {
            if let secretInput = input, secretInput.length > 0 {
                secretInput.resetBytes(in: NSRange(location: 0, length: secretInput.length))
            }
            DispatchQueue.main.async {
                completion(.failure(ADBManagerError.launchFailed(error.localizedDescription)))
            }
        }
    }

    private func startTrackerLocked() {
        let generation = UUID()
        trackerGeneration = generation
        trackParser = TrackDevicesFrameParser()
        let process = configuredProcess(arguments: ["track-devices", "-l"])
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputHandle = outputPipe.fileHandleForReading
        trackOutputHandle = outputHandle
        outputHandle.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // FileHandle continues dispatching readability callbacks at EOF
                // until its handler is removed, otherwise a stopped tracker spins.
                handle.readabilityHandler = nil
                return
            }
            guard let self, let process else {
                handle.readabilityHandler = nil
                return
            }
            self.queue.async {
                guard self.trackProcess === process, self.trackerGeneration == generation else {
                    return
                }
                do {
                    for snapshot in try self.trackParser.append(data) {
                        DispatchQueue.main.async { self.transportHandler?(snapshot) }
                    }
                } catch {
                    process.terminate()
                }
            }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            guard let self, let process else { return }
            outputHandle.readabilityHandler = nil
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            self.queue.async {
                guard self.trackProcess === process, self.trackerGeneration == generation else {
                    return
                }
                self.trackProcess = nil
                self.trackOutputHandle = nil
                let detail = String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let error: Error? = detail.isEmpty
                    ? nil
                    : ADBManagerError.commandFailed(detail)
                // A dead tracker invalidates the entire transport snapshot.
                DispatchQueue.main.async {
                    self.transportHandler?([])
                    self.trackerStoppedHandler?(error)
                }
            }
        }
        do {
            try process.run()
            trackProcess = process
        } catch {
            outputHandle.readabilityHandler = nil
            trackOutputHandle = nil
            DispatchQueue.main.async {
                self.transportHandler?([])
                self.trackerStoppedHandler?(error)
            }
        }
    }

    private func stopTrackerLocked() {
        trackerGeneration = UUID()
        trackOutputHandle?.readabilityHandler = nil
        trackOutputHandle = nil
        trackProcess?.terminationHandler = nil
        trackProcess?.terminate()
        trackProcess = nil
        transportHandler = nil
        trackerStoppedHandler = nil
    }

    private func cancelOrdinaryProcessesLocked() {
        for process in ordinaryProcesses.values {
            process.terminationHandler = nil
            process.terminate()
        }
        ordinaryProcesses.removeAll()
    }

    private func configuredProcess(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = Self.standardServerEnvironment(
            from: ProcessInfo.processInfo.environment
        )
        return process
    }

    private static func extractVersion(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { $0.hasPrefix("Version ") }?
            .dropFirst("Version ".count)
            .split(separator: "-")
            .first
            .map(String.init)
    }

    static func standardServerIsResponsive(timeout: TimeInterval = 0.3) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var noSigPipe: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )
        let microseconds = max(1, min(timeout, 1)) * 1_000_000
        var socketTimeout = timeval(tv_sec: 0, tv_usec: Int32(microseconds))
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &socketTimeout,
            socklen_t(MemoryLayout.size(ofValue: socketTimeout))
        )
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &socketTimeout,
            socklen_t(MemoryLayout.size(ofValue: socketTimeout))
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(5037).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard connected == 0 else { return false }

        let request = Array("000chost:version".utf8)
        guard sendAll(request, to: descriptor) else { return false }
        guard let response = receive(count: 4, from: descriptor) else { return false }
        return response.elementsEqual("OKAY".utf8)
    }

    private static func sendAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset,
                    0
                )
                guard sent > 0 else { return false }
                offset += sent
            }
            return true
        }
    }

    private static func receive(count: Int, from descriptor: Int32) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let receivedAll = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let received = Darwin.recv(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset,
                    0
                )
                guard received > 0 else { return false }
                offset += received
            }
            return true
        }
        return receivedAll ? bytes : nil
    }

    private static func write(_ data: NSMutableData, to fileDescriptor: Int32) {
        var offset = 0
        while offset < data.length {
            let base = data.mutableBytes.advanced(by: offset)
            let written = Darwin.write(fileDescriptor, base, data.length - offset)
            guard written > 0 else { break }
            offset += written
        }
    }
}
