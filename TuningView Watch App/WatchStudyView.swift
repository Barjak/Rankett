import SwiftUI
import WatchKit

@main
struct TuningView_Watch_AppApp: App {
        var body: some Scene {
                WindowGroup {
                        WatchStudyView()
                }
        }
}

struct WatchStudyView: View {
        // ─────────── Connection State ───────────
        @State private var connectionState: WatchUIState = .connecting
        @State private var latestFundamental: Float?
        @State private var lastUpdateTime: Date?
        
        // ─────────── Idle Prevention ───────────
        @State private var idleTimer: Timer?
        
        private static let dateFormatter: DateFormatter = {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                return df
        }()
        
        var body: some View {
                VStack(spacing: 8) {
                        // ─────────── Data Display ───────────
                        if let f = latestFundamental {
                                Text("\(f, specifier: "%.1f") Hz")
                                        .font(.system(size: 28, weight: .medium, design: .rounded))
                                        .foregroundColor(.green)
                                
                                // Show the last update timestamp
                                if let updateTime = lastUpdateTime {
                                        Text("Updated at \(updateTime, formatter: Self.dateFormatter)")
                                                .font(.system(size: 14))
                                                .foregroundColor(.gray)
                                }
                        } else {
                                // ─────────── Loading/Error States ───────────
                                switch connectionState {
                                case .connecting:
                                        ProgressView()
                                                .progressViewStyle(.circular)
                                        Text("Connecting...")
                                                .font(.system(size: 16))
                                                .foregroundColor(.gray)
                                        
                                case .phoneAppInactive:
                                        Image(systemName: "iphone.slash")
                                                .font(.title2)
                                                .foregroundColor(.orange)
                                        Text("Open iPhone app")
                                                .font(.system(size: 16))
                                                .foregroundColor(.orange)
                                        
                                case .connectionLost:
                                        Image(systemName: "wifi.slash")
                                                .font(.title2)
                                                .foregroundColor(.red)
                                        Text("Connection lost")
                                                .font(.system(size: 16))
                                                .foregroundColor(.red)
                                        
                                case .error(let message):
                                        Image(systemName: "exclamationmark.triangle")
                                                .font(.title2)
                                                .foregroundColor(.red)
                                        Text(message)
                                                .font(.system(size: 14))
                                                .foregroundColor(.red)
                                                .multilineTextAlignment(.center)
                                        
                                case .receiving:
                                        // We're receiving but no data yet
                                        ProgressView()
                                                .progressViewStyle(.circular)
                                        Text("Waiting for data...")
                                                .font(.system(size: 16))
                                                .foregroundColor(.gray)
                                }
                        }
                        
                        // ─────────── Connection Status Icon ───────────
                        Image(systemName: isConnected
                              ? "antenna.radiowaves.left.and.right"
                              : "antenna.radiowaves.left.and.right.slash"
                        )
                        .font(.caption)
                        .foregroundColor(isConnected ? .green : .red)
                }
                .padding()
                .onAppear {
                        setupConnection()
                        preventIdleTimeout()
                }
                .onDisappear {
                        teardownConnection()
                }
        }
        
        // ─────────── Computed Properties ───────────
        private var isConnected: Bool {
                switch connectionState {
                case .receiving:
                        return latestFundamental != nil
                case .connecting:
                        return false
                default:
                        return false
                }
        }
        
        // ─────────── Connection Management ───────────
        private func setupConnection() {
                // Set up callbacks
                WatchConnectionManager.shared.onUIStateChanged = { state in
                        DispatchQueue.main.async {
                                self.connectionState = state
                                
                                // Clear data on disconnect
                                if case .connectionLost = state {
                                        self.latestFundamental = nil
                                        self.lastUpdateTime = nil
                                }
                        }
                }
                
                WatchConnectionManager.shared.onDataReceived = { values in
                        DispatchQueue.main.async {
                                // Assuming first value is the fundamental frequency
                                if let fundamental = values.first {
                                        self.latestFundamental = fundamental
                                        self.lastUpdateTime = Date()
                                }
                        }
                }
                
                // Start the connection
                WatchConnectionManager.shared.start()
        }
        
        private func teardownConnection() {
                WatchConnectionManager.shared.stop()
                idleTimer?.invalidate()
                idleTimer = nil
        }
        
        // ─────────── Idle Prevention ───────────
        private func preventIdleTimeout() {
                // Prevent the watch from sleeping
                WKExtension.shared().isAutorotating = false
                
                // Keep the screen on by playing haptic feedback periodically
                idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                        // Play subtle haptic to keep app active
                        WKInterfaceDevice.current().play(.click)
                }
        }
}
