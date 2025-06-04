import Foundation
import SwiftUI

struct ContentView: View {
        // MARK: – Analysis engine
        @StateObject private var audioProcessor: AudioProcessor
        @StateObject private var study: Study
        
        /// We keep `watchForwarder` as a plain @State optional, because we only create it once `startProcessing()` is called.
        @State private var watchForwarder: WatchForwarder?
        
        // A simple string that accumulates all log lines:
        @State private var debugText: String = ""
        
        // MARK: – Layout & UI
        @Environment(\.layoutParameters) private var layout: LayoutParameters
        @State private var isProcessing = false
        @State private var controlsHeight: CGFloat = 0
        
        // MARK: – Tuning state (UI-only placeholders)
        @State private var targetedNote: String = "A4"
        @State private var incrementSteps: Int = 1
        @State private var temperament: Temperament = .equal
        @State private var partialIndex: Int = 1
        @State private var a440: Double = 440.00
        
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
                                
                                // ────────── DEBUG LOG ─────────
                                Divider().padding(.top, 8)
                                
                                ScrollView {
                                        // Show every line of debugText in a fixed-width font
                                        Text(debugText)
                                                .font(.system(.body, design: .monospaced))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(8)
                                }
                                .background(Color(UIColor.systemGray6))
                                .frame(maxHeight: 200) // or whatever “debug pane” height you like
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
                study.stop()
                audioProcessor.stop()
                watchForwarder = nil
                isProcessing = false
        }
        
        private func toggleProcessing() {
                if isProcessing {
                        self.stopProcessing()
                } else {
                        self.startProcessing()
                }
                isProcessing.toggle()
        }
        
        private func startProcessing() {
                audioProcessor.start()
                study.start()
                
                // Create a new WatchForwarder, passing in a closure that appends logs to `debugText`.
                watchForwarder = WatchForwarder(study: study) { newLine in
                        // Always dispatch back to the main thread, because Combine/WatchConnectivity callbacks can come on arbitrary queues.
                        DispatchQueue.main.async {
                                // Append the new line, plus a newline character.
                                debugText = newLine + "\n"
                        }
                }
                
                isProcessing = true
        }
        
        private func autoTune() {
                // TODO: Implement auto-tune logic when back-end is in place.
        }
        
        // MARK: – Supporting types
        
        enum Temperament: String, CaseIterable, Identifiable {
                case equal = "Equal"
                case neidhardt = "Neidhardt"
                case quarterCommaMeantone = "Quarter-comma Meantone"
                case kleineStadt = "Kleine Stadt"
                var id: String { rawValue }
        }
        
        // MARK: - Updated TuningControlsView with fat-finger friendly controls
        struct TuningControlsView: View {
                @Binding var targetedNote: String
                @Binding var incrementSteps: Int
                @Binding var temperament: Temperament
                @Binding var partialIndex: Int
                @Binding var a440: Double
                @Binding var isProcessing: Bool
                
                @State private var showTemperamentConfig = false
                @State private var deviationUnit: DeviationUnit = .cents
                
                var startStopAction: () -> Void
                var autoTuneAction: () -> Void
                
                private let buttonSize: CGFloat = 44
                private let largeButtonSize: CGFloat = 52
                
                private var currentNote: Note {
                        let parts = targetedNote.split(separator: Character(String(targetedNote.last!)))
                        if parts.count >= 1, let octave = Int(String(targetedNote.last!)) {
                                let noteName = String(targetedNote.dropLast())
                                return Note(name: noteName, octave: octave)
                        }
                        return Note(name: "A", octave: 4)
                }
                
                var body: some View {
                        VStack(spacing: 12) {
                                // Top row: Start/Stop and Auto
                                HStack(spacing: 16) {
                                        Button(action: startStopAction) {
                                                Label(isProcessing ? "Stop" : "Start",
                                                      systemImage: isProcessing ? "stop.circle.fill" : "play.circle.fill")
                                                .font(.headline)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.large)
                                        
                                        Spacer()
                                        
                                        Button(action: autoTuneAction) {
                                                Label("Auto", systemImage: "wand.and.stars")
                                                        .font(.headline)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.large)
                                }
                                .padding(.horizontal)
                                
                                // Note display and controls
                                VStack(spacing: 8) {
                                        Text(targetedNote)
                                                .font(.system(size: 56, weight: .bold, design: .rounded))
                                                .frame(height: 60)
                                        
                                        HStack(spacing: 8) {
                                                Button(action: { adjustNote(by: -12) }) {
                                                        Image(systemName: "chevron.left.2")
                                                                .font(.title2)
                                                }
                                                .buttonStyle(.bordered)
                                                .frame(width: largeButtonSize, height: largeButtonSize)
                                                
                                                Button(action: decrementNote) {
                                                        Image(systemName: "minus.circle.fill")
                                                                .font(.title)
                                                }
                                                .buttonStyle(.bordered)
                                                .frame(width: largeButtonSize, height: largeButtonSize)
                                                
                                                VStack(spacing: 2) {
                                                        Text("Step")
                                                                .font(.caption2)
                                                                .foregroundColor(.secondary)
                                                        Picker("Steps", selection: $incrementSteps) {
                                                                Text("1").tag(1)
                                                                Text("2").tag(2)
                                                                Text("3").tag(3)
                                                                Text("12").tag(12)
                                                        }
                                                        .pickerStyle(.segmented)
                                                        .frame(width: 140)
                                                }
                                                
                                                Button(action: incrementNote) {
                                                        Image(systemName: "plus.circle.fill")
                                                                .font(.title)
                                                }
                                                .buttonStyle(.bordered)
                                                .frame(width: largeButtonSize, height: largeButtonSize)
                                                
                                                Button(action: { adjustNote(by: 12) }) {
                                                        Image(systemName: "chevron.right.2")
                                                                .font(.title2)
                                                }
                                                .buttonStyle(.bordered)
                                                .frame(width: largeButtonSize, height: largeButtonSize)
                                        }
                                }
                                .padding(.horizontal)
                                
                                // Temperament and settings row
                                HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                                Text("Temperament")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                
                                                HStack(spacing: 8) {
                                                        Picker("", selection: $temperament) {
                                                                ForEach(Temperament.allCases) { temp in
                                                                        Text(temp.rawValue).tag(temp)
                                                                }
                                                        }
                                                        .pickerStyle(.menu)
                                                        .frame(minWidth: 180)
                                                        
                                                        Button(action: { showTemperamentConfig = true }) {
                                                                Image(systemName: "gearshape.fill")
                                                        }
                                                        .buttonStyle(.bordered)
                                                        .frame(width: buttonSize, height: buttonSize)
                                                }
                                        }
                                        
                                        Spacer()
                                        
                                        VStack(spacing: 4) {
                                                Text("Units")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                
                                                Picker("", selection: $deviationUnit) {
                                                        Text("¢").tag(DeviationUnit.cents)
                                                        Text("PC").tag(DeviationUnit.pythagorean)
                                                }
                                                .pickerStyle(.segmented)
                                                .frame(width: 80)
                                        }
                                }
                                .padding(.horizontal)
                                
                                // Bottom row: Partial and A440
                                HStack(spacing: 32) {
                                        VStack(spacing: 4) {
                                                Text("Partial")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                
                                                HStack(spacing: 8) {
                                                        Button(action: { if partialIndex > 1 { partialIndex -= 1 } }) {
                                                                Image(systemName: "minus.circle.fill")
                                                        }
                                                        .buttonStyle(.bordered)
                                                        .frame(width: buttonSize, height: buttonSize)
                                                        .disabled(partialIndex <= 1)
                                                        
                                                        Text("\(partialIndex)")
                                                                .font(.title2)
                                                                .monospacedDigit()
                                                                .frame(minWidth: 30)
                                                        
                                                        Button(action: { partialIndex += 1 }) {
                                                                Image(systemName: "plus.circle.fill")
                                                        }
                                                        .buttonStyle(.bordered)
                                                        .frame(width: buttonSize, height: buttonSize)
                                                }
                                        }
                                        
                                        VStack(spacing: 4) {
                                                Text("Reference")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                
                                                HStack(spacing: 8) {
                                                        Button(action: { a440 -= 0.01 }) {
                                                                Image(systemName: "minus.circle.fill")
                                                        }
                                                        .buttonStyle(.bordered)
                                                        .frame(width: buttonSize, height: buttonSize)
                                                        
                                                        Text(String(format: "%.2f Hz", a440))
                                                                .font(.system(.body, design: .monospaced))
                                                                .frame(minWidth: 80)
                                                        
                                                        Button(action: { a440 += 0.01 }) {
                                                                Image(systemName: "plus.circle.fill")
                                                        }
                                                        .buttonStyle(.bordered)
                                                        .frame(width: buttonSize, height: buttonSize)
                                                }
                                        }
                                }
                                .padding(.horizontal)
                                .padding(.bottom, 8)
                        }
                        .padding(.vertical, 12)
                        .sheet(isPresented: $showTemperamentConfig) {
                                TemperamentConfigView(
                                        temperament: $temperament,
                                        deviationUnit: $deviationUnit
                                )
                        }
                }
                
                private func incrementNote() {
                        adjustNote(by: incrementSteps)
                }
                
                private func decrementNote() {
                        adjustNote(by: -incrementSteps)
                }
                
                private func adjustNote(by semitones: Int) {
                        let note = currentNote.transposed(by: semitones)
                        targetedNote = note.displayName
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
                                        Form {
                                                Section("Temperament Selection") {
                                                        Picker("Temperament", selection: $temperament) {
                                                                ForEach(Temperament.allCases) { temp in
                                                                        Text(temp.rawValue).tag(temp)
                                                                }
                                                        }
                                                }
                                                
                                                Section("Deviation Units") {
                                                        Picker("Units", selection: $deviationUnit) {
                                                                Text("Cents").tag(DeviationUnit.cents)
                                                                Text("Pythagorean Commas").tag(DeviationUnit.pythagorean)
                                                        }
                                                        .pickerStyle(.segmented)
                                                }
                                                
                                                Section("Custom Temperament") {
                                                        Text("Custom temperament configuration coming soon...")
                                                                .foregroundColor(.secondary)
                                                }
                                        }
                                        .navigationTitle("Temperament Configuration")
                                        .navigationBarTitleDisplayMode(.inline)
                                        .toolbar {
                                                ToolbarItem(placement: .confirmationAction) {
                                                        Button("Done") { dismiss() }
                                                }
                                        }
                                }
                        }
                }
        }
}
