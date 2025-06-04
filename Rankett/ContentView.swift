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
                var params = LayoutParameters()
                
#if os(iOS)
                // Nothing here yet
#endif
                
                return params
        }
}
struct ContentView: View {
        // ─────────── Shared Tuning Parameters ───────────
        /// This store holds concert pitch, target pitch, end‐correction settings, temperament, etc.
        @StateObject private var store = TuningParameterStore()
        
        // ─────────── Analysis Engine ───────────
        /// AudioProcessor drives `parameters.actualPitch` (and hence `centsError`, `beatFrequency`, etc.)
        @StateObject private var audioProcessor: AudioProcessor
        /// Study consumes the same `parameters` to compute whatever visualization values it needs
        @StateObject private var study: Study
        
        /// If you have a phone/watch forwarding object, tie it here:
        @State private var phoneConnection = PhoneConnectionManager()
        
        // ─────────── Layout & UI Helpers ───────────
        @Environment(\.layoutParameters) private var layout: LayoutParameters
        @State private var isProcessing = false
        
        // Because we have three @StateObjects (parameters, audioProcessor, study),
        // we must initialize them all in `init()` before calling any super initializer.
        init() {
                // 1) Create the single TuningParameterStore
                _store = StateObject(wrappedValue: store)
                
                // 2) Instantiate AudioProcessor with that same store
                //    (replace `parameterStore:` with your actual init if needed)
                _audioProcessor = StateObject(
                        wrappedValue: AudioProcessor(store: store)
                )
                
                // 3) Instantiate Study with that same store
                _study = StateObject(
                        wrappedValue: Study(audioProcessor: self.audioProcessor, store: store)
                )
                
                // 4) The phoneConnection can remain a plain @State
                _phoneConnection = State(initialValue: PhoneConnectionManager())
        }
        
        var body: some View {
                NavigationView {
                        GeometryReader { geo in
                                VStack(spacing: 0) {
                                        // ─────────── PLOTS ───────────
                                        // Pass the `study` wrapper in—any visualization that needs audio data
                                        // comes from `study`, which itself is reading from `parameters`.
                                        StudyView(study: study, store: store)
                                                .background(Color.black)
                                                .frame(
                                                        minHeight: geo.size.height * layout.studyHeightFraction,
                                                        maxHeight: layout.maxPanelHeight
                                                        ?? (geo.size.height * layout.studyHeightFraction)
                                                )
                                                .layoutPriority(1)
                                        
                                        // ────────── CONTROLS ─────────
                                        // The `TuningControlsView` will now read/write directly against
                                        // our shared `parameters` object.
                                        TuningControlsView(store: store)
                                                .background(Color(uiColor: .secondarySystemBackground))
                                                .frame(maxWidth: 640)
                                                .padding(.vertical)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .onAppear {
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
        
        // ─────────── Engine Control Helpers ───────────
        private func startProcessing() {
                audioProcessor.start()
                study.start()
                
                // Example: start sending data to watch every 0.1s
                phoneConnection.getReady()
                phoneConnection.startSendFramesLoop(
                        every: 0.1
                ) {
                        // Supply whatever packet you need, e.g.:
                        // return watchPacket(study.currentValue)
                }
                
                isProcessing = true
        }
        
        private func stopProcessing() {
                audioProcessor.stop()
                study.stop()
                phoneConnection.stopSendFramesLoop()
                isProcessing = false
        }
}
