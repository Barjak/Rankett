import SwiftUI
import WatchConnectivity

final class WatchStudyModel: NSObject, ObservableObject, WCSessionDelegate {
        @Published var latestFundamental: Float? = nil
        @Published var lastUpdateTime: Date? = nil
        @Published var isConnected: Bool = false
        
        private var updateCount = 0
        private var messageCount = 0
        
        override init() {
                super.init()
                if WCSession.isSupported() {
                        let session = WCSession.default
                        session.delegate = self
                        session.activate()
                        
                        print("✅ Watch: WCSession setup with main queue")
                }
        }
        
        func session(_ session: WCSession,
                     activationDidCompleteWith activationState: WCSessionActivationState,
                     error: Error?)
        {
                if let error = error {
                        print("❌ Watch: Activation failed: \(error)")
                } else {
                        print("✅ Watch: Activated with state: \(activationState.rawValue)")
                        DispatchQueue.main.async {
                                self.isConnected = activationState == .activated
                        }
                }
        }
        
        // Handle updateApplicationContext (preferred for streaming data)
        func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
                messageCount += 1
                print("📨 Watch: Received MESSAGE #\(messageCount) at \(Date())")
                processUpdate(message, source: "message")
        }
        
        // Handle updateApplicationContext (state sync)
        func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
                updateCount += 1
                print("📦 Watch: Received CONTEXT #\(updateCount) at \(Date())")
                processUpdate(applicationContext, source: "context")
        }
        
        private func processUpdate(_ data: [String: Any], source: String) {
                guard let fundamental = data["fundamental"] as? Float,
                      let timestamp = data["timestamp"] as? TimeInterval else {
                        print("❌ Watch: Invalid data from \(source)")
                        return
                }
                
                let receiveTime = Date()
                let updateTime = Date(timeIntervalSince1970: timestamp)
                let latency = receiveTime.timeIntervalSince(updateTime) * 1000
                
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "HH:mm:ss.SSS"
                
                print("🎵 Watch [\(source)]: \(String(format: "%.2f", fundamental)) Hz")
                print("   Sent: \(dateFormatter.string(from: updateTime))")
                print("   Recv: \(dateFormatter.string(from: receiveTime))")
                print("   Latency: \(String(format: "%.1f", latency)) ms")
                
                // Update UI immediately on main thread
                DispatchQueue.main.async { [weak self] in
                        self?.latestFundamental = fundamental
                        self?.lastUpdateTime = updateTime
                }
        }
}

struct WatchStudyView: View {
        @StateObject private var model = WatchStudyModel()
        @State private var idleTimer: Timer?
        
        private static let dateFormatter: DateFormatter = {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"  // “.SSS” → milliseconds
                return df
        }()
        
        var body: some View {
                VStack(spacing: 8) {
                        if let f = model.latestFundamental {
                                Text("\(f, specifier: "%.1f") Hz")
                                        .font(.system(size: 28, weight: .medium, design: .rounded))
                                        .foregroundColor(.green)
                                
                                // Show the last update timestamp (with milliseconds)
                                if let updateTime = model.lastUpdateTime {
                                        Text("Updated at \(updateTime, formatter: Self.dateFormatter)")
                                                .font(.system(size: 14))
                                                .foregroundColor(.gray)
                                }
                        } else {
                                ProgressView()
                                        .progressViewStyle(.circular)
                                
                                Text("Waiting for data…")
                                        .font(.system(size: 16))
                                        .foregroundColor(.gray)
                        }
                        
                        // Connection status
                        Image(systemName: model.isConnected
                              ? "antenna.radiowaves.left.and.right"
                              : "antenna.radiowaves.left.and.right.slash"
                        )
                        .font(.caption)
                        .foregroundColor(model.isConnected ? .green : .red)
                }
                .padding()
                .onAppear {
                        // Prevent the watch from sleeping
                        WKExtension.shared().isAutorotating = false
                        
                        // Keep the screen on by updating something periodically
                        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                                // This keeps the app active
                                WKInterfaceDevice.current().play(.click)
                        }
                }
                .onDisappear {
                        idleTimer?.invalidate()
                }
        }
        
        
}
