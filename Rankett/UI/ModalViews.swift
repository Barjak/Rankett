import Foundation
import SwiftUI


struct DisplayModeSelector: View {
        @Binding var selectedMode: NumericalDisplayMode
        @Binding var isPresented: Bool
        
        var body: some View {
                NavigationView {
                        List {
                                ForEach(NumericalDisplayMode.allCases, id: \.self) { mode in
                                        Button(action: {
                                                selectedMode = mode
                                                isPresented = false
                                        }) {
                                                HStack {
                                                        Text(mode.rawValue)
                                                        Spacer()
                                                        if selectedMode == mode {
                                                                Image(systemName: "checkmark")
                                                                        .foregroundColor(.accentColor)
                                                        }
                                                }
                                        }
                                }
                        }
                        .navigationTitle("Display Mode")
                        .navigationBarItems(
                                trailing: Button("Done") { isPresented = false }
                        )
                }
        }
}

struct IncrementSettingsModal: View {
        @Binding var incrementSemitones: Int
        @Binding var isPresented: Bool
        @State private var wholeScaleRoot = 0 // 0 = C, 1 = C#
        @State private var thirdScaleRoot = 0 // 0-3 for C, C#, D, D#
        
        var body: some View {
                NavigationView {
                        Form {
                                Section("Increment Size") {
                                        Picker("Semitones", selection: $incrementSemitones) {
                                                Text("1 Semitone").tag(1)
                                                Text("2 Semitones (Whole Tone)").tag(2)
                                                Text("4 Semitones (Major Third)").tag(4)
                                        }
                                        .pickerStyle(.segmented)
                                }
                                
                                if incrementSemitones == 2 {
                                        Section("Whole Tone Scale") {
                                                Picker("Root", selection: $wholeScaleRoot) {
                                                        Text("C").tag(0)
                                                        Text("C#").tag(1)
                                                }
                                                .pickerStyle(.segmented)
                                        }
                                }
                                
                                if incrementSemitones == 4 {
                                        Section("Major Third Group") {
                                                Picker("Root", selection: $thirdScaleRoot) {
                                                        Text("C").tag(0)
                                                        Text("C#").tag(1)
                                                        Text("D").tag(2)
                                                        Text("D#").tag(3)
                                                }
                                                .pickerStyle(.segmented)
                                        }
                                }
                        }
                        .navigationTitle("Pitch Increment Settings")
                        .navigationBarItems(
                                trailing: Button("Done") { isPresented = false }
                        )
                }
        }
}

struct TemperamentModal: View {
        @Binding var temperament: Temperament
        @Binding var isPresented: Bool
        
        var body: some View {
                NavigationView {
                        VStack {
                                // Temperament deviation matrix
                                VStack {
                                        Text("Deviation from Equal Temperament")
                                                .font(.headline)
                                                .padding(.top)
                                        
                                        TemperamentDeviationMatrix(temperament: temperament)
                                                .padding()
                                }
                                
                                // Temperament selector
                                List {
                                        ForEach(Temperament.allCases, id: \.self) { temp in
                                                Button(action: {
                                                        temperament = temp
                                                }) {
                                                        HStack {
                                                                Text(temp.rawValue)
                                                                Spacer()
                                                                if temperament == temp {
                                                                        Image(systemName: "checkmark")
                                                                                .foregroundColor(.accentColor)
                                                                }
                                                        }
                                                }
                                        }
                                }
                                
                                // Editor button
                                Button(action: {
                                        // Navigate to temperament editor
                                }) {
                                        Label("Edit Temperament", systemImage: "slider.horizontal.3")
                                }
                                .buttonStyle(TuningButtonStyle())
                                .padding()
                        }
                        .navigationTitle("Temperament")
                        .navigationBarItems(
                                trailing: Button("Done") { isPresented = false }
                        )
                }
        }
}

struct TemperamentDeviationMatrix: View {
        let temperament: Temperament
        
        private let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        
        // Simplified deviation values - in real app these would be calculated
        private func deviation(for noteIndex: Int) -> Double {
                switch temperament {
                case .equal:
                        return 0.0
                case .justIntonation:
                        return [0, -10, 4, 16, -14, -2, -12, 2, 14, -16, 18, -16][noteIndex]
                default:
                        return 0.0
                }
        }
        
        var body: some View {
                VStack(spacing: 8) {
                        HStack(spacing: 4) {
                                ForEach(0..<12) { index in
                                        VStack(spacing: 4) {
                                                Text(noteNames[index])
                                                        .font(.caption)
                                                        .frame(width: 25)
                                                
                                                Text(String(format: "%+.0f", deviation(for: index)))
                                                        .font(.caption2.monospaced())
                                                        .foregroundColor(deviation(for: index) == 0 ? .primary :
                                                                                deviation(for: index) > 0 ? .red : .blue)
                                                        .frame(width: 25)
                                        }
                                }
                        }
                        Text("cents")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                }
                .padding()
                .background(
                        RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.1))
                )
        }
}

struct InstrumentModal: View {
        @Binding var instrument: Instrument
        @Binding var isPresented: Bool
        
        let availableInstruments = [
                Instrument(name: "Principal 8'", overtoneProfile: [1.0, 0.5, 0.33, 0.25, 0.2, 0.17, 0.14, 0.125], pipeScale: 138.0, wallThickness: 0.0),
                Instrument(name: "Flute 8'", overtoneProfile: [1.0, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001], pipeScale: 155.0, wallThickness: 2.0),
                Instrument(name: "String 8'", overtoneProfile: [1.0, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2], pipeScale: 100.0, wallThickness: 0.5)
        ]
        
        var body: some View {
                NavigationView {
                        VStack {
                                // Overtone profile display
                                VStack(alignment: .leading) {
                                        Text("Overtone Profile")
                                                .font(.headline)
                                        
                                        ForEach(0..<8) { index in
                                                HStack {
                                                        Text("Partial \(index + 1):")
                                                                .frame(width: 80)
                                                        
                                                        GeometryReader { geometry in
                                                                ZStack(alignment: .leading) {
                                                                        RoundedRectangle(cornerRadius: 4)
                                                                                .fill(Color.gray.opacity(0.2))
                                                                        
                                                                        RoundedRectangle(cornerRadius: 4)
                                                                                .fill(Color.accentColor)
                                                                                .frame(width: geometry.size.width * instrument.overtoneProfile[index])
                                                                }
                                                        }
                                                        .frame(height: 20)
                                                        
                                                        Text(String(format: "%.2f", instrument.overtoneProfile[index]))
                                                                .font(.caption.monospaced())
                                                                .frame(width: 40)
                                                }
                                        }
                                        
                                        HStack {
                                                Label("Pipe Scale: \(Int(instrument.pipeScale)) mm", systemImage: "ruler")
                                                Spacer()
                                                Label("Wall: \(instrument.wallThickness, specifier: "%.1f") mm", systemImage: "square.split.diagonal")
                                        }
                                        .font(.caption)
                                        .padding(.top)
                                }
                                .padding()
                                
                                // Instrument selector
                                List {
                                        ForEach(availableInstruments) { inst in
                                                Button(action: {
                                                        instrument = inst
                                                }) {
                                                        HStack {
                                                                Text(inst.name)
                                                                Spacer()
                                                                if instrument.id == inst.id {
                                                                        Image(systemName: "checkmark")
                                                                                .foregroundColor(.accentColor)
                                                                }
                                                        }
                                                }
                                        }
                                }
                                
                                // Editor button
                                Button(action: {
                                        // Navigate to instrument editor
                                }) {
                                        Label("Edit Instrument", systemImage: "slider.horizontal.3")
                                }
                                .buttonStyle(TuningButtonStyle())
                                .padding()
                        }
                        .navigationTitle("Instrument")
                        .navigationBarItems(
                                trailing: Button("Done") { isPresented = false }
                        )
                }
        }
}
