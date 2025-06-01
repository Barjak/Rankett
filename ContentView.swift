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
        @StateObject private var study: Study
        @Environment(\.layoutParameters) private var layout: LayoutParameters
        @State private var isProcessing = false
        
        init() {
                let config = AnalyzerConfig.default
                let processor = AudioProcessor(config: config)
                _audioProcessor = StateObject(wrappedValue: processor)
                _study = StateObject(wrappedValue: Study(audioProcessor: processor, config: config))
        }
        
        var body: some View {
                GeometryReader { geo in
                        VStack(spacing: 0) {
                                // MARK: - Study View (now much larger)
                                StudyView(study: study)
                                        .background(Color.black)
                                        .frame(
                                                maxWidth: .infinity,
                                                minHeight: geo.size.height * layout.studyHeightFraction,
                                                maxHeight: layout.maxPanelHeight ?? 1000
                                        )
                                        .layoutPriority(1)
                                
                                // MARK: - Controls
                                HStack(spacing: 16) {
                                        Button {
                                                toggleProcessing()
                                        } label: {
                                                Label(
                                                        isProcessing ? "Stop" : "Start",
                                                        systemImage: isProcessing ? "stop.circle.fill" : "play.circle.fill"
                                                )
                                        }
                                        .buttonStyle(.borderedProminent)
                                }
                                .font(.body)
                                .frame(height: 44)
                                .padding()
                                
                                Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear { startProcessing() }
                .onDisappear {
                        study.stop()
                        audioProcessor.stop()
                }
                .navigationTitle("Spectrum Analyzer")
                .edgesIgnoringSafeArea(.horizontal)
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
        }
        
        private func toggleProcessing() {
                if isProcessing {
                        study.stop()
                        audioProcessor.stop()
                } else {
                        startProcessing()
                }
                isProcessing.toggle()
        }
        
        private func startProcessing() {
                audioProcessor.start()
                study.start()
                isProcessing = true
        }
}
