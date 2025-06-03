import Foundation
struct Note: Equatable, Hashable {
        let name: String
        let octave: Int
        let midiNumber: Int
        
        var displayName: String { "\(name)\(octave)" }
        
        static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        
        init(midiNumber: Int) {
                self.midiNumber = midiNumber
                self.octave = (midiNumber / 12) - 1
                let noteIndex = midiNumber % 12
                self.name = Self.noteNames[noteIndex]
        }
        
        init(name: String, octave: Int) {
                self.name = name
                self.octave = octave
                if let noteIndex = Self.noteNames.firstIndex(of: name) {
                        self.midiNumber = (octave + 1) * 12 + noteIndex
                } else {
                        self.midiNumber = 69 // Default to A4
                }
        }
        
        func transposed(by semitones: Int) -> Note {
                return Note(midiNumber: midiNumber + semitones)
        }
        
        var frequency: Double {
                // A4 = 440 Hz, MIDI 69
                return 440.0 * pow(2.0, Double(midiNumber - 69) / 12.0)
        }
        
        func frequency(withA4: Double) -> Double {
                return withA4 * pow(2.0, Double(midiNumber - 69) / 12.0)
        }
}
