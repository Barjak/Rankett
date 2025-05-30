import SwiftUI

private struct LayoutParametersKey: EnvironmentKey {
        static let defaultValue = LayoutParameters()
}

extension EnvironmentValues {
        var layoutParameters: LayoutParameters {
                get { self[LayoutParametersKey.self] }
                set { self[LayoutParametersKey.self] = newValue }
        }
}

struct ContentView: View {
        @StateObject private var audioProcessor: AudioProcessor
        @Environment(\.layoutParameters) private var layout
        @State private var isProcessing = false
        
        init() {
                let config = AnalyzerConfig.default
                _audioProcessor = StateObject(wrappedValue: AudioProcessor(config: config))
        }
        
        var body: some View {
                GeometryReader { geo in
                        VStack(spacing: 20) {
                                
                                // MARK: - Spectrum View
                                SpectrumView(
                                        spectrumData: audioProcessor.spectrumData,
                                        config: audioProcessor.config
                                )
                                .background(Color.black)
                                .cornerRadius(12)
                                .shadow(radius: 4)
                                .frame(
                                        maxWidth: .infinity,
                                        maxHeight: min(
                                                geo.size.height * layout.spectrumHeightFraction,
                                                layout.maxPanelHeight ?? .infinity
                                        )
                                )
                                .layoutPriority(1)
                                
                                // MARK: - Study View
                                if audioProcessor.studyResult != nil {
                                        StudyView(studyResult: audioProcessor.studyResult)
                                                .background(Color.black)
                                                .cornerRadius(12)
                                                .shadow(radius: 4)
                                                .frame(
                                                        maxWidth: .infinity,
                                                        maxHeight: min(
                                                                geo.size.height * layout.studyHeightFraction,
                                                                layout.maxPanelHeight ?? .infinity
                                                        )
                                                )
                                                .layoutPriority(1)
                                }
                                
                                // MARK: - Controls
                                HStack(spacing: 16) {
                                        Button("Analyze Spectrum") {
                                                audioProcessor.triggerStudy()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(audioProcessor.studyInProgress)
                                        
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
                                
                                Spacer()
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear { startProcessing() }
                .onDisappear { audioProcessor.stop() }
                .navigationTitle("Spectrum Analyzer")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
        }
        
        // MARK: - Control Helpers
        private func toggleProcessing() {
                isProcessing ? audioProcessor.stop() : startProcessing()
                isProcessing.toggle()
        }
        
        private func startProcessing() {
                audioProcessor.start()
                isProcessing = true
        }
}

// MARK: - Study Section View
struct StudySection: View {
        let study: StudyResult?
        
        var body: some View {
                if let study = study {
                        StudyView(studyResult: study)
                                .background(Color.black)
                                .cornerRadius(12)
                                .shadow(radius: 4)
                } else {
                        RoundedRectangle(cornerRadius: 12)
                                .fill(Color.black.opacity(0.3))
                                .overlay(
                                        Text("Run analysis to see results")
                                                .foregroundColor(.gray)
                                )
                }
        }
}
