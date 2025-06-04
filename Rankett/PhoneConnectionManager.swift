//
//  PhoneConnectionManager.swift
//  iPhone App
//
//  Real-time communication manager for iPhone to Apple Watch using WatchConnectivity
//

import Foundation
import WatchConnectivity

// MARK: - State Definitions

enum PhoneAppState {
        case notRunning
        case background
        case foreground
}

enum PhoneWCState {
        case notActivated
        case activating
        case activated
        case inactive      // Multiple watch scenario
        case deactivated   // After watch switch
        case failed(Error)
}

enum PhoneConnectionState {
        case disconnected
        case checkingReachability
        case reachable(lastPingTime: Date)
        case unreachable(since: Date)
}

enum PhoneUIState {
        case searching          // "Looking for watch..."
        case connected          // "✓ Connected"
        case watchAppInactive   // "Open watch app"
        case watchNotPaired     // "Pair your Apple Watch"
        case error(String)      // Custom error message
}

// MARK: - Message Types

enum MessagePriority {
        case realtime      // Drop if can't send immediately
        case guaranteed    // Use transferUserInfo if needed
}

struct Message {
        let data: [String: Any]
        let priority: MessagePriority
        let timestamp: Date
}

// MARK: - Connection Manager

class PhoneConnectionManager: NSObject {
        
        // MARK: - Singleton
        static let shared = PhoneConnectionManager()
        
        // MARK: - Properties
        
        // State tracking
        private var appState: PhoneAppState = .notRunning
        private var wcState: PhoneWCState = .notActivated
        private var connectionState: PhoneConnectionState = .disconnected
        
        // Timers
        private var reachabilityTimer: Timer?
        private var heartbeatTimer: Timer?
        private var reachabilityDebouncer: Timer?
        
        // Configuration
        private let reachabilityCheckInterval = 1.0  // seconds
        private let heartbeatInterval = 5.0           // seconds
        private let staleDataThreshold = 0.5         // seconds
        private let reachabilityDebounceInterval = 0.5
        
        // Tracking
        private var sequenceNumber: UInt64 = 0
        private var failureCount = 0
        private let maxConsecutiveFailures = 3
        
        // Callbacks
        var onUIStateChanged: ((PhoneUIState) -> Void)?
        var onDataReceived: (([String: Any]) -> Void)?
        
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
        
        func sendData(_ values: [Float], guaranteed: Bool = false) {
                let message: [String: Any] = [
                        "type": "data",
                        "values": values,
                        "timestamp": Date().timeIntervalSince1970,
                        "sequence": nextSequenceNumber()
                ]
                
                if guaranteed {
                        sendGuaranteedMessage(message)
                } else {
                        sendRealtimeMessage(message)
                }
        }
        
        // MARK: - App Lifecycle
        
        private func setupNotifications() {
                NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(handleAppDidBecomeActive),
                        name: UIApplication.didBecomeActiveNotification,
                        object: nil
                )
                
                NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(handleAppDidEnterBackground),
                        name: UIApplication.didEnterBackgroundNotification,
                        object: nil
                )
                
                NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(handleAppWillTerminate),
                        name: UIApplication.willTerminateNotification,
                        object: nil
                )
        }
        
        @objc private func handleAppDidBecomeActive() {
                appState = .foreground
                
                switch wcState {
                case .notActivated:
                        activateWCSession()
                case .activated:
                        startReachabilityMonitoring()
                        checkWatchStatus()
                case .deactivated:
                        // Re-activate after watch switch
                        activateWCSession()
                default:
                        break
                }
                
                updateUIState()
        }
        
        @objc private func handleAppDidEnterBackground() {
                appState = .background
                stopReachabilityMonitoring()
                
                // Send any pending guaranteed messages
                flushGuaranteedMessages()
                updateUIState()
        }
        
        @objc private func handleAppWillTerminate() {
                cleanup()
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
        
        private func checkWatchStatus() {
                if case .activated = wcState {
                        
                        if !WCSession.default.isPaired {
                                connectionState = .disconnected
                                updateUIState()
                                return
                        }
                        
                        if !WCSession.default.isWatchAppInstalled {
                                connectionState = .disconnected
                                updateUIState()
                                return
                        }
                        
                        checkReachability()
                }
        }
        
        // MARK: - Connection Monitoring
        
        private func startReachabilityMonitoring() {
                stopReachabilityMonitoring()
                
                reachabilityTimer = Timer.scheduledTimer(
                        withTimeInterval: reachabilityCheckInterval,
                        repeats: true
                ) { [weak self] _ in
                        self?.checkReachability()
                }
                
                // Start heartbeat
                heartbeatTimer = Timer.scheduledTimer(
                        withTimeInterval: heartbeatInterval,
                        repeats: true
                ) { [weak self] _ in
                        self?.sendHeartbeat()
                }
        }
        
        private func stopReachabilityMonitoring() {
                reachabilityTimer?.invalidate()
                reachabilityTimer = nil
                heartbeatTimer?.invalidate()
                heartbeatTimer = nil
        }
        
        private func checkReachability() {
                if case .activated = wcState {
                        let isReachable = WCSession.default.isReachable
                        
                        switch (connectionState, isReachable) {
                        case (.disconnected, true), (.unreachable, true):
                                connectionState = .reachable(lastPingTime: Date())
                                sendHeartbeat()
                                failureCount = 0
                                
                        case (.reachable(let lastPing), true):
                                // Update ping time if we're actively communicating
                                if Date().timeIntervalSince(lastPing) > heartbeatInterval {
                                        sendHeartbeat()
                                }
                                
                        case (.reachable, false), (.checkingReachability, false):
                                connectionState = .unreachable(since: Date())
                                
                        default:
                                break
                        }
                        
                        updateUIState()
                }
        }
        
        // MARK: - Message Sending
        
        private func sendRealtimeMessage(_ message: [String: Any]) {
                // Check data freshness
                if let timestamp = message["timestamp"] as? TimeInterval {
                        if Date().timeIntervalSince1970 - timestamp > staleDataThreshold {
                                // Drop stale message
                                return
                        }
                }
                
                // Only send if reachable
                guard case .reachable = connectionState,
                      WCSession.default.isReachable else {
                        // Drop message - don't queue
                        return
                }
                
                WCSession.default.sendMessage(message, replyHandler: nil) { [weak self] error in
                        // Message failed - don't retry realtime messages
                        print("Realtime message dropped: \(error)")
                        self?.failureCount += 1
                        
                        if self?.failureCount ?? 0 > self?.maxConsecutiveFailures ?? 3 {
                                self?.handleCommunicationFailure()
                        }
                }
        }
        
        private func sendGuaranteedMessage(_ message: [String: Any]) {
                // Always use transferUserInfo for guaranteed delivery
                WCSession.default.transferUserInfo(message)
        }
        
        private func sendHeartbeat() {
                guard case .reachable = connectionState else { return }
                
                let heartbeat: [String: Any] = [
                        "type": "heartbeat",
                        "timestamp": Date().timeIntervalSince1970
                ]
                
                WCSession.default.sendMessage(heartbeat, replyHandler: { [weak self] reply in
                        // Heartbeat acknowledged
                        if case .reachable = self?.connectionState {
                                self?.connectionState = .reachable(lastPingTime: Date())
                        }
                }, errorHandler: { [weak self] error in
                        print("Heartbeat failed: \(error)")
                        self?.checkReachability()
                })
        }
        
        private func flushGuaranteedMessages() {
                // In a real app, you might have a queue of guaranteed messages to send
                // For now, just send a status update
                sendGuaranteedMessage([
                        "type": "statusUpdate",
                        "phoneState": "background",
                        "timestamp": Date().timeIntervalSince1970
                ])
        }
        
        // MARK: - Utilities
        
        private func nextSequenceNumber() -> UInt64 {
                sequenceNumber += 1
                return sequenceNumber
        }
        
        private func cleanup() {
                stopReachabilityMonitoring()
                reachabilityDebouncer?.invalidate()
                reachabilityDebouncer = nil
        }
        
        private func handleCommunicationFailure() {
                // Reset connection state and try to recover
                connectionState = .disconnected
                failureCount = 0
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.checkReachability()
                }
        }
        
        private func updateUIState() {
                let uiState: PhoneUIState
                
                switch (wcState, connectionState) {
                case (.activated, .reachable):
                        uiState = .connected
                        
                case (.activated, .unreachable):
                        uiState = .watchAppInactive
                        
                case (.activated, .disconnected):
                        if !WCSession.default.isPaired {
                                uiState = .watchNotPaired
                        } else if !WCSession.default.isWatchAppInstalled {
                                uiState = .error("Watch app not installed")
                        } else {
                                uiState = .watchAppInactive
                        }
                        
                case (.activating, _):
                        uiState = .searching
                        
                case (.failed(let error), _):
                        uiState = .error(error.localizedDescription)
                        
                default:
                        uiState = .error("Connection unavailable")
                }
                
                DispatchQueue.main.async { [weak self] in
                        self?.onUIStateChanged?(uiState)
                }
        }
}

// MARK: - WCSessionDelegate

extension PhoneConnectionManager: WCSessionDelegate {
        
        func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
                DispatchQueue.main.async { [weak self] in
                        if let error = error {
                                self?.wcState = .failed(error)
                                self?.updateUIState()
                                return
                        }
                        
                        switch state {
                        case .activated:
                                self?.wcState = .activated
                                if self?.appState == .foreground {
                                        self?.startReachabilityMonitoring()
                                        self?.checkWatchStatus()
                                }
                                
                        case .inactive:
                                self?.wcState = .inactive
                                self?.connectionState = .disconnected
                                
                        case .notActivated:
                                self?.wcState = .notActivated
                                
                        @unknown default:
                                break
                        }
                        
                        self?.updateUIState()
                }
        }
        
        func sessionReachabilityDidChange(_ session: WCSession) {
                // Debounce rapid changes
                reachabilityDebouncer?.invalidate()
                reachabilityDebouncer = Timer.scheduledTimer(
                        withTimeInterval: reachabilityDebounceInterval,
                        repeats: false
                ) { [weak self] _ in
                        self?.checkReachability()
                }
        }
        
        func sessionDidBecomeInactive(_ session: WCSession) {
                wcState = .inactive
                connectionState = .disconnected
                updateUIState()
        }
        
        func sessionDidDeactivate(_ session: WCSession) {
                wcState = .deactivated
                // Re-activate for new watch
                session.activate()
        }
        
        // MARK: - Message Reception
        
        func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
                handleReceivedMessage(message)
        }
        
        func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
                handleReceivedMessage(message)
                replyHandler(["status": "received", "timestamp": Date().timeIntervalSince1970])
        }
        
        func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
                handleReceivedMessage(userInfo)
        }
        
        private func handleReceivedMessage(_ message: [String: Any]) {
                // Update connection state if we're receiving messages
                if case .unreachable = connectionState {
                        connectionState = .reachable(lastPingTime: Date())
                        updateUIState()
                }
                
                // Handle different message types
                if let messageType = message["type"] as? String {
                        switch messageType {
                        case "connectionRequest", "wakePhone":
                                // Watch is requesting connection
                                sendGuaranteedMessage([
                                        "type": "connectionConfirmed",
                                        "timestamp": Date().timeIntervalSince1970
                                ])
                                
                        case "data":
                                // Forward to app
                                DispatchQueue.main.async { [weak self] in
                                        self?.onDataReceived?(message)
                                }
                                
                        default:
                                break
                        }
                }
        }
}

// MARK: - Error Types

enum ConnectionError: LocalizedError {
        case unsupported
        case activationFailed
        case watchNotPaired
        case watchAppNotInstalled
        case prolongedUnreachable
        
        var errorDescription: String? {
                switch self {
                case .unsupported:
                        return "Watch Connectivity not supported"
                case .activationFailed:
                        return "Failed to activate connection"
                case .watchNotPaired:
                        return "No Apple Watch paired"
                case .watchAppNotInstalled:
                        return "Watch app not installed"
                case .prolongedUnreachable:
                        return "Watch unreachable for extended period"
                }
        }
}
