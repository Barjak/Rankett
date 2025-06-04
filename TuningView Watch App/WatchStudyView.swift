import SwiftUI
import WatchConnectivity

final class WatchStudyModel: NSObject, ObservableObject, WCSessionDelegate {
        @Published var latestFundamental: Float? = nil
        @Published var lastUpdateTime: Date? = nil
        @Published var isConnected: Bool = false
        
        override init() {
                super.init()
                if WCSession.isSupported() {
                        let session = WCSession.default
                        session.delegate = self
                        session.activate()
                        print("✅ Watch: WCSession setup initiated")
                } else {
                        print("❌ Watch: WCSession not supported")
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
        func session(_ session: WCSession,
                     didReceiveApplicationContext applicationContext: [String : Any])
        {
                print("📥 Watch: Received context update")
                processUpdate(applicationContext)
        }
        
        // Handle sendMessage (fallback for when app is active)
        func session(_ session: WCSession,
                     didReceiveMessage message: [String : Any])
        {
                print("📥 Watch: Received message")
                processUpdate(message)
        }
        
        private func processUpdate(_ data: [String: Any]) {
                if let fundamental = data["fundamental"] as? Float,
                   let timestamp = data["timestamp"] as? TimeInterval {
                        
                        // 1. Recreate the Date from the TimeInterval (seconds since 1970)
                        let updateTime = Date(timeIntervalSince1970: timestamp)
                        
                        // 2. Format `updateTime` so it shows milliseconds
                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"  // ".SSS" = milliseconds
                        let updateTimeString = dateFormatter.string(from: updateTime)
                        
                        // 3. Compute latency in milliseconds
                        let latency = Date().timeIntervalSince(updateTime) * 1000
                        
                        // 4. Print everything
                        print(
                                "🎵 Watch: Fundamental: \(String(format: "%.2f", fundamental)) Hz " +
                                "at \(updateTimeString), Latency: \(String(format: "%.1f", latency)) ms"
                        )
                        
                        DispatchQueue.main.async {
                                self.latestFundamental = fundamental
                                self.lastUpdateTime = updateTime
                        }
                }
        }
}

struct WatchStudyView: View {
        @StateObject private var model = WatchStudyModel()
        
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
        }
}
