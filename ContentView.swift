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
        
        // Additional state for configuration
        @State private var showTemperamentConfig = false
        @State private var deviationUnit: DeviationUnit = .cents
        
        // Callbacks
        var startStopAction: () -> Void
        var autoTuneAction: () -> Void
        
        var body: some View {
                VStack(spacing: 20) {
                        // Top row: Playback controls
                        HStack(spacing: 16) {
                                Button(action: startStopAction) {
                                        Label(isProcessing ? "Stop" : "Start",
                                              systemImage: isProcessing ? "stop.circle.fill" : "play.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                
                                Spacer()
                                
                                Button(action: autoTuneAction) {
                                        Label("Auto", systemImage: "wand.and.stars")
                                }
                                .buttonStyle(.borderedProminent)
                                .help("Auto-tune based on current note and audio stream")
                        }
                        .font(.body)
                        
                        // Large targeted note display with increment/decrement
                        VStack(spacing: 16) {
                                Text(targetedNote)
                                        .font(.system(size: 72, weight: .bold, design: .rounded))
                                        .minimumScaleFactor(0.5)
                                        .frame(maxWidth: .infinity)
                                
                                HStack(spacing: 20) {
                                        Button(action: { decrementNote() }) {
                                                Image(systemName: "minus.circle.fill")
                                                        .font(.system(size: 36))
                                        }
                                        .buttonStyle(.borderless)
                                        
                                        VStack(spacing: 4) {
                                                Text("Step Size")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                Picker("Increment", selection: $incrementSteps) {
                                                        ForEach([1, 2, 3, 12], id: \.self) { value in
                                                                Text("\(value)").tag(value)
                                                        }
                                                }
                                                .pickerStyle(.segmented)
                                                .frame(width: 200)
                                        }
                                        
                                        Button(action: { incrementNote() }) {
                                                Image(systemName: "plus.circle.fill")
                                                        .font(.system(size: 36))
                                        }
                                        .buttonStyle(.borderless)
                                }
                        }
                        
                        Divider()
                        
                        // Temperament section
                        HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                        Text("Temperament")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        
                                        Picker("Temperament", selection: $temperament) {
                                                ForEach(Temperament.allCases) { temp in
                                                        Text(temp.rawValue).tag(temp)
                                                }
                                        }
                                        .pickerStyle(.menu)
                                        .frame(minWidth: 200)
                                }
                                
                                Button(action: { showTemperamentConfig = true }) {
                                        Label("Configure", systemImage: "slider.horizontal.3")
                                }
                                .buttonStyle(.bordered)
                                
                                Picker("Units", selection: $deviationUnit) {
                                        Text("Cents").tag(DeviationUnit.cents)
                                        Text("Pythagorean").tag(DeviationUnit.pythagorean)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 160)
                        }
                        
                        // Partial and A440 controls
                        HStack(spacing: 40) {
                                // Partial selector
                                VStack(spacing: 8) {
                                        Text("Partial")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        
                                        HStack(spacing: 12) {
                                                Button(action: { partialIndex = max(1, partialIndex - 1) }) {
                                                        Image(systemName: "minus.circle.fill")
                                                                .font(.title2)
                                                }
                                                .buttonStyle(.borderless)
                                                .disabled(partialIndex <= 1)
                                                
                                                Text("\(partialIndex)")
                                                        .font(.title2)
                                                        .monospacedDigit()
                                                        .frame(minWidth: 30)
                                                
                                                Button(action: { partialIndex += 1 }) {
                                                        Image(systemName: "plus.circle.fill")
                                                                .font(.title2)
                                                }
                                                .buttonStyle(.borderless)
                                        }
                                }
                                
                                // A440 fine tuning
                                VStack(spacing: 8) {
                                        Text("Reference Pitch")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        
                                        HStack(spacing: 12) {
                                                Button(action: { a440 -= 0.01 }) {
                                                        Image(systemName: "minus.circle.fill")
                                                                .font(.title2)
                                                }
                                                .buttonStyle(.borderless)
                                                
                                                Text(String(format: "%.2f Hz", a440))
                                                        .font(.title3)
                                                        .monospacedDigit()
                                                        .frame(minWidth: 80)
                                                
                                                Button(action: { a440 += 0.01 }) {
                                                        Image(systemName: "plus.circle.fill")
                                                                .font(.title2)
                                                }
                                                .buttonStyle(.borderless)
                                        }
                                }
                        }
                }
                .padding()
                .sheet(isPresented: $showTemperamentConfig) {
                        TemperamentConfigView(
                                temperament: $temperament,
                                deviationUnit: $deviationUnit
                        )
                }
        }
        
        // Helper functions
        private func incrementNote() {
                // TODO: Implement note increment logic based on incrementSteps
        }
        
        private func decrementNote() {
                // TODO: Implement note decrement logic based on incrementSteps
        }
}

// MARK: – Supporting types
enum DeviationUnit: String, CaseIterable {
        case cents = "Cents"
        case pythagorean = "Pythagorean Commas"
}

// MARK: – Temperament Configuration View
struct TemperamentConfigView: View {
        @Binding var temperament: Temperament
        @Binding var deviationUnit: DeviationUnit
        @Environment(\.dismiss) var dismiss
        
        var body: some View {
                NavigationView {
                        VStack {
                                Text("Temperament Configuration")
                                        .font(.largeTitle)
                                        .padding()
                                
                                // TODO: Implement temperament configuration interface
                                Text("Custom temperament configuration coming soon...")
                                        .foregroundColor(.secondary)
                                        .padding()
                                
                                Spacer()
                        }
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                        Button("Done") { dismiss() }
                                }
                        }
                }
        }
}
