import Foundation
import SwiftUI
import Combine


struct NumericalPitchDisplayRow: View {
        @Binding var leftMode: NumericalDisplayMode
        @Binding var rightMode: NumericalDisplayMode
        @ObservedObject var store: TuningParameterStore
        
        @State private var showingLeftModal = false
        @State private var showingRightModal = false
        
        var body: some View {
                HStack(spacing: 12) {
                        // Left display
                        Button(action: {}) {
                                VStack {
                                        Text(displayValue(for: leftMode))
                                                .font(.system(.title2, design: .monospaced))
                                        Text(leftMode.rawValue)
                                                .font(.caption)
                                                .opacity(0.7)
                                }
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TuningButtonStyle())
                        .onLongPressGesture {
                                showingLeftModal = true
                        }
                        
                        // Right display
                        Button(action: {}) {
                                VStack {
                                        Text(displayValue(for: rightMode))
                                                .font(.system(.title2, design: .monospaced))
                                        Text(rightMode.rawValue)
                                                .font(.caption)
                                                .opacity(0.7)
                                }
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TuningButtonStyle())
                        .onLongPressGesture {
                                showingRightModal = true
                        }
                }
                .sheet(isPresented: $showingLeftModal) {
                        DisplayModeSelector(selectedMode: $leftMode, isPresented: $showingLeftModal)
                }
                .sheet(isPresented: $showingRightModal) {
                        DisplayModeSelector(selectedMode: $rightMode, isPresented: $showingRightModal)
                }
        }
        
        private func displayValue(for mode: NumericalDisplayMode) -> String {
                switch mode {
                case .cents:
                        return String(format: "%+.1f¢", store.centsError)
                case .beat:
                        return String("Not Implemented")//String(format: "%.2f Hz", store.beatFrequency)
                case .errorHz:
                        return String(format: "%+.2f Hz", store.centsError)
                case .targetHz:
                        return String(format: "%.2f Hz", store.targetNote.frequency(concertA: store.concertPitch))
                case .actualHz:
                        return String(format: "%.2f Hz", store.targetNote.frequency(concertA: store.concertPitch) + store.centsError)
                case .theoreticalLength:
                        return "1234 mm" // Placeholder
                case .lengthCorrectionNaive:
                        return "+12 mm" // Placeholder
                case .amplitudeBar, .finePitchBar:
                        return "" // These would be custom views
                }
        }
}

// MARK: - Target Pitch Row
struct TargetNoteRow: View {
        @Binding var targetNote: Note
        @Binding var incrementSemitones: Int
        @ObservedObject var study: Study
        @ObservedObject var store: TuningParameterStore

        @State private var showingIncrementModal = false
        @State private var autoTuneJobID: UUID?
        @State private var autoTuneCancellable: AnyCancellable?

        
        private func incrementNote(by semitones: Int) {
                targetNote = targetNote.transposed(by: semitones)
        }
        
        private func startAutoTune() {
                print("DEBUG: startAutoTune() called")
                let job = AutoTuneJob()
                autoTuneJobID = job.id
                print("DEBUG: Created job with ID: \(job.id)")
                
                autoTuneCancellable = study.enqueue(job)
                        .receive(on: DispatchQueue.main)
                        .sink { [self] note in
                                print("DEBUG: Job completed with result: \(String(describing: note))")
                                if let note = note {
                                        targetNote = note
                                }
                                autoTuneJobID = nil
                                autoTuneCancellable = nil
                        }
                print("DEBUG: Job enqueued from UI Side")
        }
        
        private func cancelAutoTune() {
                if let id = autoTuneJobID {
                        study.cancelJob(id: id)
                        autoTuneJobID = nil
                        autoTuneCancellable = nil
                }
        }
        
        

        
        var body: some View {
                HStack(spacing: 12) {
                        Button(action: { incrementNote(by: -12) }) {
                                Image(systemName: "chevron.left.2")
                                        .font(.title3)
                        }
                        .buttonStyle(TuningButtonStyle())
                        
                        Button(action: { incrementNote(by: -incrementSemitones) }) {
                                Image(systemName: "chevron.left")
                                        .font(.title3)
                        }
                        .buttonStyle(TuningButtonStyle())
                        .onLongPressGesture {
                                showingIncrementModal = true
                        }
                        
                        Button(action: {
                                print("DEBUG: Button tapped")
                                if autoTuneJobID != nil {
                                        print("DEBUG: Canceling auto-tune")
                                        cancelAutoTune()
                                }
                        }) {
                                VStack {
                                        Text("\(targetNote.displayName)\(targetNote.octave)")
                                                .font(.system(.title2, design: .monospaced))
                                        Text(String(format: "%.2f Hz", store.targetFrequency()))
                                                .font(.caption)
                                                .opacity(0.7)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                        RoundedRectangle(cornerRadius: 8)
                                                .fill(autoTuneJobID != nil ?
                                                      Color.red.opacity(0.6) :
                                                        Color.accentColor.opacity(0.2))
                                )
                                .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                                .stroke(autoTuneJobID != nil ? Color.red : Color.accentColor, lineWidth: 1)
                                )
                                .onTapGesture {
                                        print("DEBUG: Tap detected")
                                        if autoTuneJobID != nil {
                                                print("DEBUG: Canceling auto-tune")
                                                cancelAutoTune()
                                        }
                                }
                                .onLongPressGesture(
                                        minimumDuration: 0.5,
                                        maximumDistance: .infinity,
                                        perform: {
                                                print("DEBUG: Long press performed!")
                                                startAutoTune()
                                        },
                                        onPressingChanged: { isPressing in
                                                print("DEBUG: Pressing: \(isPressing)")
                                        }
                                )
                        }
                        
                        Button(action: { incrementNote(by: incrementSemitones) }) {
                                Image(systemName: "chevron.right")
                                        .font(.title3)
                        }
                        .buttonStyle(TuningButtonStyle())
                        .onLongPressGesture {
                                showingIncrementModal = true
                        }
                        
                        Button(action: { incrementNote(by: 12) }) {
                                Image(systemName: "chevron.right.2")
                                        .font(.title3)
                        }
                        .buttonStyle(TuningButtonStyle())
                }
                .sheet(isPresented: $showingIncrementModal) {
                        IncrementSettingsModal(
                                incrementSemitones: $incrementSemitones,
                                isPresented: $showingIncrementModal
                        )
                }
        }
}



struct TuningButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) var isEnabled
        var supportsLongPress: Bool = false
        var isAutoTuning: Bool = false
        
        func makeBody(configuration: Configuration) -> some View {
                configuration.label
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxHeight: .infinity)
                        .background(
                                RoundedRectangle(cornerRadius: 8)
                                        .fill(isAutoTuning ?
                                              Color.red.opacity(0.6) :
                                                configuration.isPressed ?
                                              Color.accentColor.opacity(0.3) :
                                                Color.accentColor.opacity(0.2))
                        )
                        .overlay(
                                ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                                .stroke(isAutoTuning ? Color.red : Color.accentColor, lineWidth: 1)
                                        
                                        if supportsLongPress {
                                                VStack {
                                                        HStack {
                                                                Spacer()
                                                                Circle()
                                                                        .fill(Color.accentColor)
                                                                        .frame(width: 6, height: 6)
                                                                        .padding(4)
                                                        }
                                                        Spacer()
                                                }
                                        }
                                }
                        )
                        .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
                        .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
                        .opacity(isEnabled ? 1.0 : 0.6)
        }
}


// MARK: - Concert Pitch Row

struct ConcertPitchRow: View {
        @Binding var concertPitch: Double
        @ObservedObject var study: Study
        @ObservedObject var store: TuningParameterStore
        
        @State private var middleButtonWidth: CGFloat = 0

        
        @State private var timer: Timer?
        @State private var autoTuneJobID: UUID?
        @State private var autoTuneCancellable: AnyCancellable?
        
        private let fineStep: Double  = 0.01
        private let coarseStep: Double = 1.0
        
        private func startIncrementing(_ amount: Double) {
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                        concertPitch += amount
                }
        }
        
        private func stopIncrementing() {
                timer?.invalidate()
                timer = nil
        }
        
        private func startAutoConcertPitch() {
                let job = AutoConcertPitchJob()
                autoTuneJobID = job.id
                
                autoTuneCancellable = study.enqueue(job)
                        .receive(on: DispatchQueue.main)
                        .sink { [self] newPitch in
                                if let pitch = newPitch {
                                        concertPitch = pitch
                                }
                                autoTuneJobID = nil
                                autoTuneCancellable = nil
                        }
        }
        
        private func cancelAutoTune() {
                if let id = autoTuneJobID {
                        study.cancelJob(id: id)
                        autoTuneJobID = nil
                        autoTuneCancellable = nil
                }
        }
        var body: some View {
                HStack(spacing: 12) {
                        // Gross down
                        Button(action: { concertPitch -= 1.0 }) {
                                Image(systemName: "minus.circle")
                                        .font(.title3)
                        }
                        .buttonStyle(TuningButtonStyle())
                        
                        // Fine down
                        Button(action: { concertPitch -= 0.01 }) {
                                Image(systemName: "minus")
                                        .font(.title3)
                        }
                        .buttonStyle(TuningButtonStyle())
                        .onLongPressGesture(
                                minimumDuration: 0.5,
                                maximumDistance: .infinity,
                                pressing: { isPressing in
                                        if isPressing {
                                                startIncrementing(-0.01)
                                        } else {
                                                stopIncrementing()
                                        }
                                },
                                perform: {}
                        )
                        
                        // Display
                        Button(action: {
                                if autoTuneJobID != nil {
                                        cancelAutoTune()
                                }
                        }) {
                                VStack {
                                        Text(String(format: "%.2f", concertPitch))
                                                .font(.system(.title3))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 2)
                                .padding(.vertical, 8)
                                .background(
                                        RoundedRectangle(cornerRadius: 8)
                                                .fill(autoTuneJobID != nil ?
                                                      Color.red.opacity(0.6) :
                                                        Color.accentColor.opacity(0.2))
                                )
                                .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                                .stroke(autoTuneJobID != nil ? Color.red : Color.accentColor, lineWidth: 1)
                                )
                                .onTapGesture {
                                        if autoTuneJobID != nil {
                                                cancelAutoTune()
                                        }
                                }
                                .onLongPressGesture(
                                        minimumDuration: 0.5,
                                        maximumDistance: .infinity,
                                        perform: {
                                                startAutoConcertPitch()
                                        }
                                )
                        }
                        
                        // Fine up
                        Button(action: { concertPitch += 0.01 }) {
                                Image(systemName: "plus")
                                        .font(.title3)
                        }
                        .buttonStyle(TuningButtonStyle())
                        .onLongPressGesture(
                                minimumDuration: 0.5,
                                maximumDistance: .infinity,
                                pressing: { isPressing in
                                        if isPressing {
                                                startIncrementing(0.01)
                                        } else {
                                                stopIncrementing()
                                        }
                                },
                                perform: {}
                        )
                        
                        // Gross up
                        Button(action: { concertPitch += 1.0 }) {
                                Image(systemName: "plus.circle")
                                        .font(.title3)
                        }
                        .buttonStyle(TuningButtonStyle())
                }
        }
}
 


// MARK: - Target Overtone Row

struct TargetOvertoneRow: View {
        @Binding var targetPartial: Int
        
        var body: some View {
                HStack(spacing: 12) {
                        Button(action: {
                                if targetPartial > 1 { targetPartial -= 1 }
                        }) {
                                Image(systemName: "minus")
                                        .font(.title3)
                        }
                        .buttonStyle(TuningButtonStyle())
                        .disabled(targetPartial <= 1)
                        
                        Button(action: {}) {
                                VStack {
                                        Text("\(targetPartial)")
                                                .font(.system(.title2, design: .monospaced))
                                        Text("Partial")
                                                .font(.caption)
                                                .opacity(0.7)
                                }
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TuningButtonStyle())
                        
                        Button(action: {
                                if targetPartial < 8 { targetPartial += 1 }
                        }) {
                                Image(systemName: "plus")
                                        .font(.title3)
                        }
                        .buttonStyle(TuningButtonStyle())
                        .disabled(targetPartial >= 8)
                }
        }
}

// MARK: - Carousel Selector Row

struct CarouselSelectorRow: View {
        @Binding var selection: Int
        @Binding var audibleToneEnabled: Bool
        @Binding var mutationTranspose: Int
        @Binding var gateTime: Double
        
        private let columns = ["Tone Generator", "Mutation", "Gate Time"]
        
        var body: some View {
                HStack(spacing: 8) {
                        Button(action: {
                                if selection > 0 { selection -= 1 }
                        }) {
                                Image(systemName: "chevron.left")
                                        .font(.caption)
                        }
                        .buttonStyle(TuningButtonStyle())
                        .frame(width: 44)
                        .disabled(selection == 0)
                        
                        ZStack {
                                ForEach(0..<columns.count, id: \.self) { index in
                                        carouselContent(for: index)
                                                .opacity(selection == index ? 1 : 0)
                                                .animation(.easeInOut(duration: 0.2), value: selection)
                                }
                        }
                        .frame(maxWidth: .infinity)
                        
                        Button(action: {
                                if selection < columns.count - 1 { selection += 1 }
                        }) {
                                Image(systemName: "chevron.right")
                                        .font(.caption)
                        }
                        .buttonStyle(TuningButtonStyle())
                        .frame(width: 44)
                        .disabled(selection == columns.count - 1)
                }
                .onChange(of: selection) { newValue in
                        // Auto-disable tone generator when not visible
                        if newValue != 0 {
                                audibleToneEnabled = false
                        }
                }
        }
        
        @ViewBuilder
        private func carouselContent(for index: Int) -> some View {
                switch index {
                case 0:
                        Toggle(isOn: $audibleToneEnabled) {
                                Label("Tone Generator", systemImage: "speaker.wave.2")
                        }
                        .toggleStyle(.button)
                        .buttonStyle(TuningButtonStyle())
                        
                case 1:
                        HStack {
                                Text("Mutation:")
                                        .font(.caption)
                                Picker("", selection: $mutationTranspose) {
                                        ForEach(-12...12, id: \.self) { value in
                                                Text("\(value > 0 ? "+" : "")\(value)")
                                                        .tag(value)
                                        }
                                }
                                .pickerStyle(.menu)
                                .buttonStyle(TuningButtonStyle())
                        }
                        
                case 2:
                        HStack {
                                Text("Gate:")
                                        .font(.caption)
                                Text("\(Int(gateTime)) ms")
                                        .font(.system(.body, design: .monospaced))
                                Stepper("", value: $gateTime, in: 10...1000, step: 10)
                                        .labelsHidden()
                        }
                        
                default:
                        EmptyView()
                }
        }
}


