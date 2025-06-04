import Foundation
import SwiftUI

/*
 End correction algorithms:
 delta_e_naive(reference_length) "Naive"
 delta_e_rayleigh(a) "Rayleigh's Simple Rule-of-Thumb End Correction"
 delta_e_parvs(a) "PARVS Model End Correction"
 delta_e_levine_schwinger_series(a, k) "Levine & Schwinger Series Expansion #1"
 delta_e_morse_ingard(a, k) "Morse & Ingard First-Order Perturbation"
 delta_e_ingard_empirical(a, k) "Ingard’s Empirical Polynomial Fit"
 delta_e_nomura_tsukamoto(a, k) "Nomura & Tsukamoto Polynomial Fit"
 delta_e_flanged(a, k) "Levine & Schwinger Flanged Pipe Expansion"
 delta_e_partial_flange(a, Rf) "Partial Flange End Correction"
 delta_e_ingard_thick_wall(a, t) "Ingard’s Thick-Wall End Correction"
 delta_e_nakamura_ueda(a, t) "Nakamura & Ueda Semi-Empirical Thick-Wall Correction"
 delta_e_direct_numerical(a, k) "Direct Numerical Integration of Radiation Impedance (Stub)"
 */

enum NoiseFloorMethod {
        case quantileRegression
}

// WARNING: VERY MUCH IN FLUX
struct AnalyzerConfig {
        
        // MARK: - Audio capture
        struct Audio {
                let sampleRate: Double = 44_100
                let nyquistMultiplier: Double = 0.5
                
                var nyquistFrequency: Double { sampleRate * nyquistMultiplier }
        }
        
        // MARK: - FFT / STFT
        struct FFT {
                let size: Int = 8192
                let outputBinCount: Int = 512
                let hopSize: Int = 512 * 8
                var frequencyResolution: Double {
                        Audio().sampleRate / Double(size)
                }
                var circularBufferSize: Int { size * 3 }
        }
        
        // MARK: - Real-time rendering
        struct Rendering {
                let targetFPS: Double = 60
                var frameInterval: TimeInterval { 1.0 / targetFPS }
                
                let smoothingFactor: Float = 0.7
                let useLogFrequencyScale: Bool = true
                let minFrequency: Double = 20
                let maxFrequency: Double = 20_000
        }
        
        // MARK: - Spectral peak detection
        struct PeakDetection {
                var minProminence: Float = 6.0
                var minDistance: Int = 5
                var minHeight: Float = -60.0
                var prominenceWindow: Int = 50
        }
        
        // MARK: - Noise-floor estimation
        struct NoiseFloor {
                var method: NoiseFloorMethod = .quantileRegression
                var thresholdOffset: Float = 5.0
                var quantile: Float = 0.02
                var smoothingSigma: Float = 10
        }
        
        var audio = Audio()
        var fft = FFT()
        var rendering = Rendering()
        var peakDetection = PeakDetection()
        var noiseFloor = NoiseFloor()
        
        static let `default` = AnalyzerConfig()
}


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
        // MARK: – Analysis engine
        @StateObject private var audioProcessor: AudioProcessor
        @StateObject private var study: Study

        @State private var phoneConnection: PhoneConnectionManager
        
        // A simple string for current log message
        @State private var debugText: String = ""
        
        // MARK: – Layout & UI
        @Environment(\.layoutParameters) private var layout: LayoutParameters
        @State private var isProcessing = false
        @State private var controlsHeight: CGFloat = 0
        
        
        init() {
                // etc
        }
        
        var body: some View {
                GeometryReader { geo in
                        VStack(spacing: 0) {
                                // ─────────── PLOTS ───────────
                                StudyView(study: study)
                                        .background(Color.black)
                                        .frame(
                                                minHeight: geo.size.height * layout.studyHeightFraction,
                                                maxHeight: layout.maxPanelHeight ?? geo.size.height * layout.studyHeightFraction
                                        )
                                        .layoutPriority(1)
                                
                                // ────────── CONTROLS ─────────
                                TuningControlsView(
                                        // TODO: Implement
                                )
                                .background(Color(uiColor: .secondarySystemBackground))
                                .frame(maxWidth: 640)
                                .padding(.vertical)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear {
                        self.startProcessing()
                }
                .onDisappear {
                        self.stopProcessing()
                }
                .navigationTitle("Spectrum Analyzer")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
        }
        
        // MARK: – Engine control helpers
        private func stopProcessing() {
                // etc
        }
        
        private func toggleProcessing() {
                // etc
        }
        
        private func startProcessing() {
                audioProcessor.start()
                study.start()
                
                watchForwarder.getReady()
                watchForwarder.startSendFramesLoop(every: 0.1, { // Every 0.1 seconds}
                        // return watchPacket(study.getValue1())
                })
                
                isProcessing = true
        }
        
}
