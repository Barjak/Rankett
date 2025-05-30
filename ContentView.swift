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
        @State private var isProcessing = false
        @State private var layoutParams = LayoutParameters()
        
        init() {
                let config = AnalyzerConfig.default
                _audioProcessor = StateObject(wrappedValue: AudioProcessor(config: config))
        }
        
        var body: some View {
                GeometryReader { geometry in
                        VStack(spacing: 20) {
                                // MARK: - Spectrum View
                                SpectrumView(
                                        spectrumData: audioProcessor.spectrumData,
                                        config: audioProcessor.configuration
                                )
                                .background(Color.black)
                                .cornerRadius(12)
                                .shadow(radius: 4)
                                .frame(
                                        maxWidth: .infinity,
                                        maxHeight: calculateHeight(
                                                for: layoutParams.spectrumHeightFraction,
                                                in: geometry.size.height,
                                                maxHeight: layoutParams.maxPanelHeight
                                        )
                                )
                                .layoutPriority(1)
                                
                                // MARK: - Study View
                                if let studyResult = audioProcessor.studyResult {
                                        StudyView(studyResult: studyResult)
                                                .background(Color.black)
                                                .cornerRadius(12)
                                                .shadow(radius: 4)
                                                .frame(
                                                        maxWidth: .infinity,
                                                        maxHeight: calculateHeight(
                                                                for: layoutParams.studyHeightFraction,
                                                                in: geometry.size.height,
                                                                maxHeight: layoutParams.maxPanelHeight
                                                        )
                                                )
                                                .layoutPriority(1)
                                } else {
                                        // Placeholder when no study result
                                        RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.black.opacity(0.3))
                                                .overlay(
                                                        Text("Tap 'Analyze Spectrum' to see results")
                                                                .foregroundColor(.secondary)
                                                )
                                                .frame(
                                                        maxWidth: .infinity,
                                                        maxHeight: calculateHeight(
                                                                for: layoutParams.studyHeightFraction,
                                                                in: geometry.size.height,
                                                                maxHeight: layoutParams.maxPanelHeight
                                                        )
                                                )
                                                .layoutPriority(1)
                                }
                                
                                // MARK: - Control Buttons
                                HStack(spacing: 16) {
                                        Button("Analyze Spectrum") {
                                                audioProcessor.triggerStudy()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(!isProcessing)
                                        
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
                                .frame(maxHeight: 44)
                                
                                Spacer()
                        }
                        .padding()
                        .environment(\.layoutParameters, layoutParams)
                        .environment(\.drawingArea, geometry.size)
                }
                .preferredColorScheme(.dark)
                .onAppear {
                        setupLayoutParameters()
                        if !isProcessing {
                                startProcessing()
                        }
                }
                .onDisappear {
                        audioProcessor.stop()
                }
                .navigationTitle("Spectrum Analyzer")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
        }
        
        // MARK: - Helper Methods
        
        private func calculateHeight(for fraction: CGFloat, in totalHeight: CGFloat, maxHeight: CGFloat?) -> CGFloat {
                let calculatedHeight = totalHeight * fraction
                if let max = maxHeight {
                        return min(calculatedHeight, max)
                }
                return calculatedHeight
        }
        
        private func setupLayoutParameters() {
#if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .pad {
                        // iPad specific settings
                        layoutParams.maxPanelHeight = 420
                        layoutParams.spectrumHeightFraction = 0.35
                        layoutParams.studyHeightFraction = 0.35
                } else {
                        // iPhone settings
                        layoutParams.maxPanelHeight = nil
                        layoutParams.spectrumHeightFraction = 0.40
                        layoutParams.studyHeightFraction = 0.40
                }
#else
                // macOS settings
                layoutParams.maxPanelHeight = 500
                layoutParams.spectrumHeightFraction = 0.40
                layoutParams.studyHeightFraction = 0.40
#endif
        }
        
        private func toggleProcessing() {
                if isProcessing {
                        audioProcessor.stop()
                } else {
                        startProcessing()
                }
                isProcessing.toggle()
        }
        
        private func startProcessing() {
                audioProcessor.start()
                isProcessing = true
        }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
        static var previews: some View {
                ContentView()
        }
}
