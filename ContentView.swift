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

// TODO: Fully REWRITE ContentView this to use the LayoutParameters (which can be found int ./Config.swift)
// TODO: Update SpectrumView and StudyView to handle reactive sizes appropriately. Should be minimum viable/reasonable change.

struct ContentView: View {
        @StateObject private var audioProcessor: AudioProcessor
        @State private var isProcessing = false
        
        init() {
                let config = Config()
                _audioProcessor = StateObject(wrappedValue: AudioProcessor(config: config))
        }
        
        import SwiftUI
        
        struct ContentView: View {
                @StateObject private var audio = AudioProcessor(config: Config())
                @State private var isProcessing = false
                
                var body: some View {
                        GeometryReader { geo in                    // ① own the full window
                                VStack(spacing: 20) {
                                        
                                        // MARK: – Expanding spectrum plot
                                        SpectrumView(spectrumData: audio.spectrumData,
                                                     config: Config())
                                        .background(Color.black)
                                        .cornerRadius(12)
                                        .shadow(radius: 4)
                                        .frame(maxWidth: .infinity,    // ② take as much width as allowed
                                               maxHeight: geo.size.height * 0.40,
                                               alignment: .top)        //   40 % of the window height
                                        .layoutPriority(1)             // ← grabs space before buttons
                                        
                                        // MARK: – Expanding study plot
                                        StudySection(study: audio.studyResult)
                                                .frame(maxWidth: .infinity,
                                                       maxHeight: geo.size.height * 0.25)
                                                .layoutPriority(1)
                                        
                                        // MARK: – Fixed-size buttons
                                        HStack(spacing: 16) {
                                                Button("Analyze Spectrum") {
                                                        audio.triggerStudy()
                                                }
                                                .buttonStyle(.borderedProminent)
                                                
                                                Button {
                                                        toggleProcessing()
                                                } label: {
                                                        Label(isProcessing ? "Stop" : "Start",
                                                              systemImage: isProcessing ? "stop.circle.fill"
                                                              : "play.circle.fill")
                                                }
                                                .buttonStyle(.bordered)
                                        }
                                        .font(.body)                       // stays readable on all devices
                                        .frame(maxHeight: 44)              // ③ keeps touch-target height
                                }
                                .padding(.horizontal)                  // safe-area aware
                                .frame(maxWidth: .infinity,            // centers content on Mac/iPad
                                       maxHeight: .infinity,
                                       alignment: .top)
                        }
                        .onAppear { startProcessing() }
                        .onDisappear { audio.stop() }
                        .navigationTitle("Spectrum Analyzer")      // nice on iPad/Mac
                }
                
                // MARK: – Control helpers
                private func toggleProcessing() {
                        isProcessing ? audio.stop() : startProcessing()
                        isProcessing.toggle()
                }
                private func startProcessing() {
                        audio.start()
                        isProcessing = true
                }
        }

