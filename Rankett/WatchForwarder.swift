import Foundation
import WatchConnectivity
import Combine

/// A simple payload for sending just the fundamental to the watch.
private struct WatchPayload: Codable {
        let hpsFundamental: Float
        let timestamp: TimeInterval
}

/// WatchForwarder listens to a Study instance and sends every update to the Watch.
/// We've removed all debounce/removeDuplicates filtering. We also take an `onLog` closure
/// so that every “print” can also be pushed into your SwiftUI view.
final class WatchForwarder: NSObject {
        private let study: Study
        private var cancellable: AnyCancellable?
        private var wcSession: WCSession?
        
        // Throttling state (still keep a minimal send‐rate hack if you want):
        private var lastSentFundamental: Float = 0
        private var lastSendTime: Date = .distantPast
        private let minSendInterval: TimeInterval = 0.1  // still allow at most 10×/s
        
        /// Called instead of raw `print(…)` so that UI can capture logs.
        private let onLog: (String) -> Void
        
        /// DESIGNATED INIT now takes an `onLog` closure.
        init(study: Study, onLog: @escaping (String) -> Void) {
                self.study = study
                self.onLog = onLog
                super.init()
                setupWCSession()
                startObservingStudy()
        }
        
        private func setupWCSession() {
                guard WCSession.isSupported() else {
                        onLog("❌ WCSession not supported on this device")
                        return
                }
                let session = WCSession.default
                session.delegate = self
                session.activate()
                self.wcSession = session
                onLog("✅ WatchForwarder: WCSession setup complete")
        }
        
        private func startObservingStudy() {
                // 🚨 REMOVED debounce/removeDuplicates. Now we forward every emitted value:
                cancellable = study.$targetHPSFundamental
                        .sink { [weak self] newFund in
                                self?.sendFundamentalToWatch(newFund)
                        }
                onLog("✅ WatchForwarder: Started observing study (no more debounce)")
        }
        
        private func sendFundamentalToWatch(_ fundamental: Float) {
                let now = Date()
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS" // “.SSS” → milliseconds
                let timestampWithMillis = dateFormatter.string(from: now)
                let timeSinceLast = now.timeIntervalSince(lastSendTime)
                let freqChange = abs(fundamental - lastSentFundamental)
                
                if timeSinceLast < minSendInterval {
                        return
                }
                
                guard let session = wcSession else {
                        onLog("❌ WatchForwarder: No WCSession available")
                        return
                }
                
                onLog("📱 WatchForwarder: Session paired=\(session.isPaired), reachable=\(session.isReachable)")
                
                let context: [String: Any] = [
                        "fundamental": fundamental,
                        "timestamp": now.timeIntervalSince1970
                ]
                
                do {
                        onLog("📤 WatchForwarder: Sending fundamental \(String(format: "%.2f", fundamental)) Hz at \(timestampWithMillis)")

                        try session.updateApplicationContext(context)
                        lastSentFundamental = fundamental
                        lastSendTime = now
                } catch {
                        onLog("❌ WatchForwarder: Failed to update context: \(error)")
                        if session.isReachable {
                                onLog("🔄 WatchForwarder: Falling back to sendMessage")
                                session.sendMessage(context, replyHandler: nil) { err in
                                        self.onLog("❌ WatchForwarder: sendMessage failed: \(err)")
                                }
                        }
                }
        }
        
        deinit {
                cancellable?.cancel()
                onLog("🗑️ WatchForwarder: Deallocated")
        }
}

extension WatchForwarder: WCSessionDelegate {
        func session(_ session: WCSession,
                     activationDidCompleteWith activationState: WCSessionActivationState,
                     error: Error?)
        {
                if let error = error {
                        onLog("❌ WatchForwarder: WCSession activation failed: \(error)")
                } else {
                        onLog("✅ WatchForwarder: WCSession activated (state: \(activationState.rawValue))")
                }
        }
        
#if os(iOS)
        func sessionDidBecomeInactive(_ session: WCSession) {
                onLog("⏸️ WatchForwarder: Session became inactive")
        }
        
        func sessionDidDeactivate(_ session: WCSession) {
                onLog("🔄 WatchForwarder: Session deactivated, reactivating…")
                session.activate()
        }
        
        func sessionReachabilityDidChange(_ session: WCSession) {
                onLog("📶 WatchForwarder: Reachability changed: \(session.isReachable)")
        }
#endif
}
