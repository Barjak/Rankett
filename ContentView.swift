import Foundation
import SwiftUI
struct LayoutParameters {
        var studyHeightFraction: CGFloat = 0.85  // Much larger now
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


struct ContentView: View {
        @StateObject private var audioProcessor: AudioProcessor
        @StateObject private var studyViewModel: StudyViewModel
        @Environment(\.layoutParameters) private var layout: LayoutParameters
        @State private var isProcessing = false
        
        init() {
                let config = AnalyzerConfig.default
                let processor = AudioProcessor(config: config)
                _audioProcessor = StateObject(wrappedValue: processor)
                _studyViewModel = StateObject(wrappedValue: StudyViewModel(audioProcessor: processor, config: config))
        }
        
        var body: some View {
                GeometryReader { geo in
                        VStack(spacing: 0) {
                                // MARK: - Study View (now much larger)
                                StudyView(viewModel: studyViewModel)
                                        .background(Color.black)
                                        .frame(
                                                maxWidth: .infinity,
                                                maxHeight: min(
                                                        geo.size.height * layout.studyHeightFraction,
                                                        layout.maxPanelHeight ?? .infinity
                                                )
                                        )
                                        .layoutPriority(1)
                                
                                // MARK: - Controls
                                HStack(spacing: 16) {
                                        Button("Analyze Spectrum") {
                                                studyViewModel.triggerStudy()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(studyViewModel.isStudying)
                                        
                                        Button {
                                                toggleProcessing()
                                        } label: {
                                                Label(
                                                        isProcessing ? "Stop" : "Start",
                                                        systemImage: isProcessing ? "stop.circle.fill" : "play.circle.fill"
                                                )
                                        }
                                        .buttonStyle(.bordered)
                                }
                                .font(.body)
                                .frame(height: 44)
                                .padding()
                                
                                Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear { startProcessing() }
                .onDisappear { audioProcessor.stop() }
                .navigationTitle("Spectrum Analyzer")
                .edgesIgnoringSafeArea(.horizontal)
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
        }
        
        private func toggleProcessing() {
                isProcessing ? audioProcessor.stop() : startProcessing()
                isProcessing.toggle()
        }
        
        private func startProcessing() {
                audioProcessor.start()
                isProcessing = true
        }
}

// MARK: - Study View Model
class StudyViewModel: ObservableObject {
        private let audioProcessor: AudioProcessor
        private let config: AnalyzerConfig
        private let studyQueue = DispatchQueue(label: "com.app.study", qos: .userInitiated)
        
        @Published var isStudying = false
        
        // Target buffers for StudyView (written by Study thread)
        @Published var targetOriginalSpectrum: [Float] = []
        @Published var targetNoiseFloor: [Float] = []
        @Published var targetDenoisedSpectrum: [Float] = []
        @Published var targetFrequencies: [Float] = []
        @Published var targetPeaks: [Peak] = []
        
        init(audioProcessor: AudioProcessor, config: AnalyzerConfig) {
                self.audioProcessor = audioProcessor
                self.config = config
        }
        
        func triggerStudy() {
                guard !isStudying else { return }
                isStudying = true
                
                studyQueue.async { [weak self] in
                        guard let self = self else { return }
                        
                        // Get audio window from processor
                        guard let audioWindow = self.audioProcessor.getWindow(size: self.config.fft.size) else {
                                DispatchQueue.main.async {
                                        self.isStudying = false
                                }
                                return
                        }
                        
                        // Perform study with raw FFT data
                        let result = Study.perform(audioWindow: audioWindow, config: self.config)
                        
                        // Update target buffers on main thread
                        DispatchQueue.main.async {
                                self.targetOriginalSpectrum = result.originalSpectrum
                                self.targetNoiseFloor = result.noiseFloor
                                self.targetDenoisedSpectrum = result.denoisedSpectrum
                                self.targetFrequencies = result.frequencies
                                self.targetPeaks = result.peaks
                                self.isStudying = false
                        }
                }
        }
}
