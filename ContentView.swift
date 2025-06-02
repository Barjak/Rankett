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
        // MARK: – Analysis engine
        @StateObject private var audioProcessor: AudioProcessor
        @StateObject private var study: Study
        
        // MARK: – Layout & UI
        @Environment(\.layoutParameters) private var layout: LayoutParameters
        @State private var isProcessing = false
        
        // MARK: – Tuning state (UI‑only placeholders)
        @State private var targetedNote: String = "A4"           // Current centre note
        @State private var incrementSteps: Int = 1                // How many semitones per tap
        @State private var temperament: Temperament = .equal      // Chosen temperament
        @State private var partialIndex: Int = 1                  // Which harmonic partial
        @State private var a440: Double = 440.00                  // Reference pitch
        
        init() {
                let config = AnalyzerConfig.default
                let processor = AudioProcessor(config: config)
                _audioProcessor = StateObject(wrappedValue: processor)
                _study = StateObject(wrappedValue: Study(audioProcessor: processor, config: config))
        }
        
        var body: some View {
                GeometryReader { geo in
                        VStack(spacing: 0) {
                                // ─────────── PLOTS ───────────
                                StudyView(study: study)
                                        .background(Color.black)
                                        .frame(
                                                maxWidth: .infinity,
                                                minHeight: geo.size.height * layout.studyHeightFraction,
                                                maxHeight: layout.maxPanelHeight ?? geo.size.height * layout.studyHeightFraction
                                        )
                                        .layoutPriority(1)
                                
                                // ────────── CONTROLS ─────────
                                TuningControlsView(
                                        targetedNote: $targetedNote,
                                        incrementSteps: $incrementSteps,
                                        temperament: $temperament,
                                        partialIndex: $partialIndex,
                                        a440: $a440,
                                        isProcessing: $isProcessing,
                                        startStopAction: toggleProcessing,
                                        autoTuneAction: autoTune
                                )
                                .background(Color(uiColor: .secondarySystemBackground))
                                .frame(maxWidth: 640)
                                .padding(.vertical)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear { startProcessing() }
                .onDisappear {
                        study.stop(); audioProcessor.stop()
                }
                .navigationTitle("Spectrum Analyzer")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
        }
        
        // MARK: – Engine control helpers
        private func toggleProcessing() {
                if isProcessing {
                        study.stop(); audioProcessor.stop()
                } else {
                        startProcessing()
                }
                isProcessing.toggle()
        }
        
        private func startProcessing() {
                audioProcessor.start(); study.start(); isProcessing = true
        }
        
        private func autoTune() {
                // TODO: Implement auto‑tune logic when back‑end is in place.
        }
}

// MARK: – Supporting types
enum Temperament: String, CaseIterable, Identifiable {
        case equal = "Equal"
        case neidhardt = "Neidhardt"
        case quarterCommaMeantone = "Quarter‑comma Meantone"
        case kleineStadt = "Kleine Stadt"
        // Add more temperaments as required
        var id: String { rawValue }
}

// MARK: – Bottom control panel
struct TuningControlsView: View {
        // Bindings from parent view
        @Binding var targetedNote: String
        @Binding var incrementSteps: Int
        @Binding var temperament: Temperament
        @Binding var partialIndex: Int
        @Binding var a440: Double
        @Binding var isProcessing: Bool
        
        // Callbacks
        var startStopAction: () -> Void
        var autoTuneAction: () -> Void
        
        var body: some View {
                VStack(spacing: 24) {
                        // Playback control row
                        HStack(spacing: 16) {
                                Button(action: startStopAction) {
                                        Label(isProcessing ? "Stop" : "Start",
                                              systemImage: isProcessing ? "stop.circle.fill" : "play.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                
                                Button("Auto Tune", action: autoTuneAction)
                                        .buttonStyle(.borderedProminent)
                        }
                        .font(.body)
                        
                        // Large targeted‑note display
                        Text(targetedNote)
                                .font(.system(size: 56, weight: .bold, design: .rounded))
                                .minimumScaleFactor(0.5)
                                .frame(maxWidth: .infinity)
                        
                        // Note increment controls
                        HStack(spacing: 12) {
                                Button { /* TODO: decrement note */ } label: {
                                        Image(systemName: "chevron.left.circle.fill").font(.largeTitle)
                                }
                                .buttonStyle(.bordered)
                                
                                Picker("Steps", selection: $incrementSteps) {
                                        ForEach([1, 2, 3, 12], id: \ .self) { value in
                                                Text("\(value)").tag(value)
                                        }
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 180)
                                
                                Button { /* TODO: increment note */ } label: {
                                        Image(systemName: "chevron.right.circle.fill").font(.largeTitle)
                                }
                                .buttonStyle(.bordered)
                        }
                        
                        // Temperament & config
                        VStack(alignment: .leading, spacing: 8) {
                                Picker("Temperament", selection: $temperament) {
                                        ForEach(Temperament.allCases) { temp in
                                                Text(temp.rawValue).tag(temp)
                                        }
                                }
                                .pickerStyle(.menu)
                                
                                Button("Configure Temperament…") {
                                        // TODO: Show temperament configuration sheet
                                }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        // Partial selection row
                        HStack(spacing: 12) {
                                Button { partialIndex = max(1, partialIndex - 1) } label: {
                                        Image(systemName: "minus.circle.fill").font(.title2)
                                }
                                Text("Partial \(partialIndex)")
                                Button { partialIndex += 1 } label: {
                                        Image(systemName: "plus.circle.fill").font(.title2)
                                }
                        }
                        
                        // A440 fine tune row
                        HStack(spacing: 12) {
                                Button { a440 -= 0.01 } label: {
                                        Image(systemName: "minus.circle.fill").font(.title2)
                                }
                                Text(String(format: "A440: %.2f Hz", a440))
                                Button { a440 += 0.01 } label: {
                                        Image(systemName: "plus.circle.fill").font(.title2)
                                }
                        }
                }
                .font(.body)
                .padding()
        }
}
