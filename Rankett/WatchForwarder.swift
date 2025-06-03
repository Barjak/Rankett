import Foundation
import WatchConnectivity
import Combine

/// A simple payload for sending just the fundamental to the watch.
private struct WatchPayload: Codable {
        let hpsFundamental: Float
        let timestamp: TimeInterval
}

/// WatchForwarder listens to a Study instance and sends updates to the Watch.
final class WatchForwarder: NSObject {
        private let study: Study
        private var cancellable: AnyCancellable?
        private var wcSession: WCSession?
        
        init(study: Study) {
                self.study = study
                super.init()
                setupWCSession()
                startObservingStudy()
        }
        
        private func setupWCSession() {
                guard WCSession.isSupported() else { return }
                let session = WCSession.default
                session.delegate = self
                session.activate()
                self.wcSession = session
        }
        
        private func startObservingStudy() {
                // Subscribe to Study.targetHPSFundamental
                cancellable = study.$targetHPSFundamental
                // If you want to throttle (e.g. only send when it actually changes by ≥ 0.5 cents),
                // you could insert `.removeDuplicates()` or `.debounce(for: .milliseconds(50), scheduler: RunLoop.main)` here.
                        .sink { [weak self] newFund in
                                self?.sendFundamentalToWatch(newFund)
                        }
        }
        
        private func sendFundamentalToWatch(_ fundamental: Float) {
                guard
                        let session = wcSession,
                        session.isPaired,
                        session.isReachable
                else {
                        return
                }
                
                let payload = WatchPayload(
                        hpsFundamental: fundamental,
                        timestamp: Date().timeIntervalSince1970
                )
                
                do {
                        let data = try JSONEncoder().encode(payload)
                        let msg: [String: Any] = ["hpsFundamental": data]
                        print("Sending")
                        session.sendMessage(msg, replyHandler: nil) { error in
                                print("❌ Failed to send fundamental to watch:", error.localizedDescription)
                        }
                        
                } catch {
                        print("❌ Encoding error in sendFundamentalToWatch:", error)
                }
        }
        
        deinit {
                cancellable?.cancel()
        }
}

extension WatchForwarder: WCSessionDelegate {
        func session(_ session: WCSession,
                     activationDidCompleteWith activationState: WCSessionActivationState,
                     error: Error?)
        {
                if let error = error {
                        print("❌ WCSession activation failed:", error.localizedDescription)
                }
        }
        
#if os(iOS)
        func sessionDidBecomeInactive(_ session: WCSession) { /* no-op */ }
        func sessionDidDeactivate(_ session: WCSession) {
                session.activate() // re-activate if old pairing goes away
        }
#endif
        
        func session(_ session: WCSession,
                     didReceiveMessage message: [String : Any])
        {
                // If the watch ever sends a “request full snapshot” or similar, handle it here.
        }
}
