import Foundation
import SwiftUI

struct LayoutParameters {
        var studyHeightFraction: CGFloat = 0.4
        var minStudyHeightFraction: CGFloat = 0.25
        var maxPanelHeight: CGFloat? = nil
}

private struct LayoutParametersKey: EnvironmentKey {
        static let defaultValue: LayoutParameters = LayoutParameters()
}

extension EnvironmentValues {
        var layoutParameters: LayoutParameters {
                get { self[LayoutParametersKey.self] }
                set { self[LayoutParametersKey.self] = newValue }
        }
}

@main
struct SpectrumAnalyzerApp: App {
        var body: some Scene {
                WindowGroup {
                        ContentView()
                                .preferredColorScheme(.dark)
                                .environment(\.layoutParameters, layoutParameters)
                }
        }
        
        // Customize layout parameters based on device
        private var layoutParameters: LayoutParameters {
                let params = LayoutParameters()
                
#if os(iOS)
                // Nothing here yet
#endif
                
                return params
        }
}
struct ContentView: View {
        // ─────────── Shared Tuning Parameters ───────────
        @StateObject private var store = TuningParameterStore()
        
        // ─────────── Analysis Engine ───────────
        @StateObject private var audioProcessor: AudioProcessor
        @StateObject private var study: Study
        
        // ─────────── Connection State ───────────
        @State private var connectionState: PhoneUIState = .searching
        @State private var sendTimer: Timer?
        
        // ─────────── Layout & UI Helpers ───────────
        @Environment(\.layoutParameters) private var layout: LayoutParameters
        @State private var isProcessing = false
        
        init() {
                let store = TuningParameterStore()
                _store = StateObject(wrappedValue: store)
                
                let audioProcessor = AudioProcessor(store: store)
                _audioProcessor = StateObject(wrappedValue: audioProcessor)
                
                _study = StateObject(
                        wrappedValue: Study(audioProcessor: audioProcessor, store: store)
                )
        }
        
        var body: some View {
                NavigationView {
                        GeometryReader { geo in
                                VStack(spacing: 0) {
                                        // ─────────── CONNECTION STATUS ───────────
                                        ConnectionStatusView(state: connectionState)
                                                .padding(.horizontal)
                                                .frame(height: 30)
                                        
                                        // ─────────── PLOTS ───────────
                                        StudyView(study: study, store: store)
                                                .background(Color.black)
                                                .frame(
                                                        minHeight: geo.size.height * layout.studyHeightFraction,
                                                        maxHeight: layout.maxPanelHeight
                                                        ?? (geo.size.height * layout.studyHeightFraction)
                                                )
                                                .layoutPriority(1)
                                        
                                        // ────────── CONTROLS ─────────
                                        TuningControlsView(store: store)
                                                .background(Color(uiColor: .secondarySystemBackground))
                                                .frame(maxWidth: 640)
                                                .padding(.vertical)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .onAppear {
                                setupConnection()
                                startProcessing()
                        }
                        .onDisappear {
                                stopProcessing()
                        }
                        .navigationTitle("Spectrum Analyzer")
#if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
#endif
                }
        }
        
        // ─────────── Connection Setup ───────────
        private func setupConnection() {
                // Set up callbacks
                PhoneConnectionManager.shared.onUIStateChanged = { state in
                        DispatchQueue.main.async {
                                self.connectionState = state
                        }
                }
                
                PhoneConnectionManager.shared.onDataReceived = { data in
                        // Handle any data from watch if needed
                        print("Received from watch: \(data)")
                }
                
                // Start the connection
                PhoneConnectionManager.shared.start()
        }
        
        // ─────────── Engine Control Helpers ───────────
        private func startProcessing() {
                audioProcessor.start()
                study.start()
                
                // Start sending data to watch
                startDataSending()
                
                isProcessing = true
        }
        
        private func stopProcessing() {
                audioProcessor.stop()
                study.stop()
                
                // Stop sending data
                stopDataSending()
                
                // Stop connection
                PhoneConnectionManager.shared.stop()
                
                isProcessing = false
        }
        
        private func startDataSending() {
                sendTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                        // Only send if we're connected
                        guard case .connected = self.connectionState else { return }
                        
                        // Send current data
                        let data = [self.study.targetHPSFundamental]
                        PhoneConnectionManager.shared.sendData(data, guaranteed: false)
                }
        }
        
        private func stopDataSending() {
                sendTimer?.invalidate()
                sendTimer = nil
        }
}

// Simple connection status view
struct ConnectionStatusView: View {
        let state: PhoneUIState
        
        var body: some View {
                HStack {
                        Image(systemName: iconName)
                                .foregroundColor(iconColor)
                        Text(statusText)
                                .font(.caption)
                        Spacer()
                }
        }
        
        private var iconName: String {
                switch state {
                case .connected: return "applewatch.radiowaves.left.and.right"
                case .searching: return "applewatch.slash"
                default: return "exclamationmark.triangle"
                }
        }
        
        private var iconColor: Color {
                switch state {
                case .connected: return .green
                case .searching: return .orange
                default: return .red
                }
        }
        
        private var statusText: String {
                switch state {
                case .connected: return "Watch Connected"
                case .searching: return "Searching..."
                case .watchAppInactive: return "Open Watch App"
                case .watchNotPaired: return "No Watch Paired"
                case .error(let msg): return msg
                }
        }
}
