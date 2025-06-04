import Foundation
import WatchConnectivity

// MARK: - State Definitions

enum WatchAppState {
        case notRunning
        case background    // Very limited, essentially suspended
        case foreground
}

enum WatchWCState {
        case notActivated
        case activating
        case activated
        case failed(Error)
}

enum WatchConnectionState {
        case disconnected
        case waitingForPhone
        case connected(lastMessageTime: Date)
}

enum WatchUIState {
        case connecting         // "Connecting..."
        case receiving          // "Live" with data display
        case phoneAppInactive   // "Open phone app"
        case connectionLost     // "Connection lost"
        case error(String)      // Error message
}


enum ConnectionError: Error {
        case unsupported
        case activationFailed
        case watchNotPaired
        case watchAppNotInstalled
        case prolongedUnreachable
}

// MARK: - Connection Manager

class WatchConnectionManager: NSObject {
        
        // MARK: - Singleton
        static let shared = WatchConnectionManager()
        
        // MARK: - Properties
        
        // State tracking
        private var appState: WatchAppState = .notRunning
        private var wcState: WatchWCState = .notActivated
        private var connectionState: WatchConnectionState = .disconnected
        
        // Timers
        private var connectionTimeoutTimer: Timer?
        private var connectionRequestTimer: Timer?
        
        // Configuration
        private let connectionTimeoutInterval = 10.0  // seconds
        private let connectionRetryInterval = 2.0     // seconds
        private let dataTimeoutInterval = 3.0         // seconds
        
        // Tracking
        private var lastDataReceived: Date?
        private var connectionAttempts = 0
        private let maxConnectionAttempts = 5
        
        // Callbacks
        var onUIStateChanged: ((WatchUIState) -> Void)?
        var onDataReceived: (([Float]) -> Void)?
        
        // MARK: - Initialization
        
        override init() {
                super.init()
                setupNotifications()
        }
        
        deinit {
                cleanup()
        }
        
        // MARK: - Public Interface
        
        func start() {
                handleAppDidBecomeActive()
        }
        
        func stop() {
                cleanup()
        }
        
        func sendCommand(_ command: String, guaranteed: Bool = false) {
                let message: [String: Any] = [
                        "type": "command",
                        "command": command,
                        "timestamp": Date().timeIntervalSince1970
                ]
                
                if guaranteed {
                        sendGuaranteedMessage(message)
                } else {
                        sendRealtimeMessage(message)
                }
        }
        
        // MARK: - App Lifecycle
        
        private func setupNotifications() {
                // WatchKit apps use different notifications
                NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(handleAppDidBecomeActive),
                        name: .init("WKApplicationDidBecomeActiveNotification"),
                        object: nil
                )
                
                NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(handleAppWillResignActive),
                        name: .init("WKApplicationWillResignActiveNotification"),
                        object: nil
                )
        }
        
        @objc private func handleAppDidBecomeActive() {
                appState = .foreground
                
                if case .activated = wcState {
                        connectionState = .waitingForPhone
                        requestConnection()
                } else if case .notActivated = wcState {
                        activateWCSession()
                        
                }
                startConnectionMonitoring()
                updateUIState()
        }
        
        @objc private func handleAppWillResignActive() {
                appState = .background
                // Watch apps get suspended almost immediately
                connectionState = .disconnected
                stopConnectionMonitoring()
                updateUIState()
        }
        
        // MARK: - WatchConnectivity Setup
        
        private func activateWCSession() {
                guard WCSession.isSupported() else {
                        wcState = .failed(ConnectionError.unsupported)
                        updateUIState()
                        return
                }
                
                wcState = .activating
                WCSession.default.delegate = self
                WCSession.default.activate()
                updateUIState()
        }
        
        // MARK: - Connection Management
        
        private func requestConnection() {
                connectionAttempts += 1
                
                // Send a "wake up" message to phone if possible
                if WCSession.default.isReachable {
                        let request: [String: Any] = [
                                "type": "connectionRequest",
                                "timestamp": Date().timeIntervalSince1970
                        ]
                        
                        WCSession.default.sendMessage(
                                request,
                                replyHandler: { [weak self] _ in
                                        self?.handleConnectionEstablished()
                                },
                                errorHandler: { [weak self] _ in
                                        // Try guaranteed delivery
                                        self?.sendConnectionWakeup()
                                }
                        )
                } else {
                        // Use transferUserInfo to wake phone app
                        sendConnectionWakeup()
                }
                
                // Set timeout for connection attempt
                connectionTimeoutTimer?.invalidate()
                connectionTimeoutTimer = Timer.scheduledTimer(
                        withTimeInterval: connectionTimeoutInterval,
                        repeats: false
                ) { [weak self] _ in
                        self?.handleConnectionTimeout()
                }
        }
        
        private func sendConnectionWakeup() {
                sendGuaranteedMessage([
                        "type": "wakePhone",
                        "timestamp": Date().timeIntervalSince1970
                ])
        }
        
        private func handleConnectionEstablished() {
                connectionTimeoutTimer?.invalidate()
                connectionState = .connected(lastMessageTime: Date())
                connectionAttempts = 0
                updateUIState()
        }
        
        private func handleConnectionTimeout() {
                if connectionAttempts < maxConnectionAttempts {
                        // Retry connection
                        connectionRequestTimer = Timer.scheduledTimer(
                                withTimeInterval: connectionRetryInterval,
                                repeats: false
                        ) { [weak self] _ in
                                self?.requestConnection()
                        }
                } else {
                        // Max attempts reached
                        connectionState = .disconnected
                        connectionAttempts = 0
                        updateUIState()
                }
        }
        
        // MARK: - Connection Monitoring
        
        private func startConnectionMonitoring() {
                // Monitor for data timeout
                Timer.scheduledTimer(
                        withTimeInterval: 1.0,
                        repeats: true
                ) { [weak self] timer in
                        guard self?.appState == .foreground else {
                                timer.invalidate()
                                return
                        }
                        
                        self?.checkConnectionHealth()
                }
        }
        
        private func stopConnectionMonitoring() {
                connectionTimeoutTimer?.invalidate()
                connectionRequestTimer?.invalidate()
        }
        
        private func checkConnectionHealth() {
                guard case .connected = connectionState else { return }
                
                if let lastData = lastDataReceived,
                   Date().timeIntervalSince(lastData) > dataTimeoutInterval {
                        // Haven't received data recently
                        connectionState = .waitingForPhone
                        requestConnection()
                        updateUIState()
                }
        }
        
        // MARK: - Message Sending
        
        private func sendRealtimeMessage(_ message: [String: Any]) {
                guard WCSession.default.isReachable else { return }
                
                WCSession.default.sendMessage(message, replyHandler: nil) { error in
                        print("Watch realtime message failed: \(error)")
                }
        }
        
        private func sendGuaranteedMessage(_ message: [String: Any]) {
                WCSession.default.transferUserInfo(message)
        }
        
        // MARK: - Utilities
        
        private func cleanup() {
                stopConnectionMonitoring()
        }
        
        private func updateUIState() {
                let uiState: WatchUIState
                
                switch (wcState, connectionState) {
                case (.activated, .connected):
                        uiState = .receiving
                        
                case (.activated, .waitingForPhone):
                        uiState = .connecting
                        
                case (.activated, .disconnected):
                        if connectionAttempts >= maxConnectionAttempts {
                                uiState = .phoneAppInactive
                        } else {
                                uiState = .connecting
                        }
                        
                case (.activating, _):
                        uiState = .connecting
                        
                case (.failed(let error), _):
                        uiState = .error(error.localizedDescription)
                        
                default:
                        uiState = .connectionLost
                }
                
                DispatchQueue.main.async { [weak self] in
                        self?.onUIStateChanged?(uiState)
                }
        }
}

// MARK: - WCSessionDelegate

extension WatchConnectionManager: WCSessionDelegate {
        
        func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
                DispatchQueue.main.async { [weak self] in
                        if let error = error {
                                self?.wcState = .failed(error)
                                self?.updateUIState()
                                return
                        }
                        
                        if state == .activated {
                                self?.wcState = .activated
                                if self?.appState == .foreground {
                                        self?.connectionState = .waitingForPhone
                                        self?.requestConnection()
                                }
                        } else {
                                self?.wcState = .notActivated
                        }
                        
                        self?.updateUIState()
                }
        }
        
        func sessionReachabilityDidChange(_ session: WCSession) {
                DispatchQueue.main.async { [weak self] in
                        if session.isReachable {
                                // Phone became reachable
                                if case .waitingForPhone = self?.connectionState {
                                        self?.requestConnection()
                                }
                        } else {
                                // Phone became unreachable
                                if case .connected = self?.connectionState {
                                        self?.connectionState = .disconnected
                                        self?.updateUIState()
                                }
                        }
                }
        }
        
        // MARK: - Message Reception
        
        func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
                handleReceivedMessage(message)
        }
        
        func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
                handleReceivedMessage(message)
                replyHandler(["status": "received"])
        }
        
        func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
                handleReceivedMessage(userInfo)
        }
        
        private func handleReceivedMessage(_ message: [String: Any]) {
                lastDataReceived = Date()
                
                // Update connection state
                if case .waitingForPhone = connectionState {
                        handleConnectionEstablished()
                } else if case .disconnected = connectionState {
                        connectionState = .connected(lastMessageTime: Date())
                        updateUIState()
                }
                
                // Handle different message types
                if let messageType = message["type"] as? String {
                        switch messageType {
                        case "data":
                                if let values = message["values"] as? [Float] {
                                        DispatchQueue.main.async { [weak self] in
                                                self?.onDataReceived?(values)
                                        }
                                }
                                
                        case "heartbeat":
                                // Connection is alive, update timestamp
                                if case .connected = connectionState {
                                        connectionState = .connected(lastMessageTime: Date())
                                }
                                
                        case "connectionConfirmed":
                                handleConnectionEstablished()
                                
                        case "statusUpdate":
                                // Handle status updates from phone
                                print("Phone status: \(message)")
                                
                        default:
                                break
                        }
                }
        }
}
