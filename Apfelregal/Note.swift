import Foundation

struct Note: Equatable, Hashable {
        let name: String
        let octave: Int
        let midiNumber: Int
        
        enum NotationType {
                case organNotation
                case pianoNotation
        }
        
        static let noteNames    = ["C", "Cs", "D", "Ds", "E", "F", "Fs", "G", "Gs", "A", "As", "B"]
        static let displayNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        
        var displayName: String {
                let noteIndex = midiNumber % 12
                return Self.displayNames[noteIndex]
        }
        
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
        
        init(name: String, notation: NotationType = .organNotation) {
                // Parse note name and octave from string
                var noteName = ""
                var octaveStr = ""
                var isUppercase = false
                
                if notation == .organNotation {
                        // Organ notation: C-2, C-1, C, c, c1, c2, etc.
                        if let firstChar = name.first {
                                isUppercase = firstChar.isUppercase
                                noteName = String(firstChar.uppercased())
                                
                                // Handle sharp/flat symbols
                                let restOfString = String(name.dropFirst())
                                if restOfString.hasPrefix("♯") || restOfString.hasPrefix("#") || restOfString.hasPrefix("s") {
                                        noteName += "s"
                                        octaveStr = String(restOfString.dropFirst())
                                } else if restOfString.hasPrefix("♭") || restOfString.hasPrefix("b") {
                                        // Handle flat by going down a semitone
                                        if let noteIndex = Self.noteNames.firstIndex(of: noteName) {
                                                let flatIndex = (noteIndex - 1 + 12) % 12
                                                noteName = Self.noteNames[flatIndex]
                                        }
                                        octaveStr = String(restOfString.dropFirst())
                                } else {
                                        octaveStr = restOfString
                                }
                                
                                // Determine octave based on case and number
                                var octave: Int
                                if isUppercase {
                                        if octaveStr.isEmpty {
                                                octave = 3 // C = C3
                                        } else if let num = Int(octaveStr) {
                                                octave = 3 + num // C-2 = C1, C-1 = C2
                                        } else {
                                                octave = 3
                                        }
                                } else {
                                        // Lowercase
                                        if octaveStr.isEmpty {
                                                octave = 4 // c = C4
                                        } else if let num = Int(octaveStr) {
                                                octave = 4 + num // c1 = C5, c2 = C6
                                        } else {
                                                octave = 4
                                        }
                                }
                                
                                self.init(name: noteName, octave: octave)
                        } else {
                                self.init(midiNumber: 69) // Default to A4
                        }
                } else {
                        // Piano notation: C0, C1, C2, C3, C4, etc.
                        var i = 0
                        let chars = Array(name)
                        
                        // Get note name
                        if i < chars.count {
                                noteName = String(chars[i].uppercased())
                                i += 1
                                
                                // Check for sharp/flat
                                if i < chars.count {
                                        if chars[i] == "♯" || chars[i] == "#" {
                                                noteName += "s"
                                                i += 1
                                        } else if chars[i] == "♭" || chars[i] == "b" {
                                                // Handle flat by going down a semitone
                                                if let noteIndex = Self.noteNames.firstIndex(of: noteName) {
                                                        let flatIndex = (noteIndex - 1 + 12) % 12
                                                        noteName = Self.noteNames[flatIndex]
                                                }
                                                i += 1
                                        }
                                }
                                
                                // Get octave number
                                octaveStr = String(chars[i...])
                                if let octave = Int(octaveStr) {
                                        self.init(name: noteName, octave: octave)
                                } else {
                                        self.init(midiNumber: 69) // Default to A4
                                }
                        } else {
                                self.init(midiNumber: 69) // Default to A4
                        }
                }
        }
        
        func transposed(by semitones: Int) -> Note {
                return Note(midiNumber: midiNumber + semitones)
        }
        
        func frequency(concertA: Double) -> Double {
                return concertA * pow(2.0, Double(midiNumber - 69) / 12.0)
        }
        
        static func calculateZoomCenterFrequency(centerFreq: Double, totalWindowCents: Double = 100.0) -> (lower: Double, upper: Double) {
                let centsToLower = -totalWindowCents / 2.0
                let centsToUpper = totalWindowCents / 2.0
                
                // Convert cents to frequency multiplier: freq * 2^(cents/1200)
                let lowerHz = centerFreq * pow(2.0, centsToLower / 1200.0)
                let upperHz = centerFreq * pow(2.0, centsToUpper / 1200.0)
                
                return (lowerHz, upperHz)
        }
        
        static func getClosestNote(frequency: Double, concertA: Double = 440.0) -> (note: Note, errorCents: Double) {
                // Calculate MIDI number from frequency
                let midiNumberExact = 69.0 + 12.0 * log2(frequency / concertA)
                let midiNumberRounded = Int(round(midiNumberExact))
                
                // Create the note
                let note = Note(midiNumber: midiNumberRounded)
                
                // Calculate error in cents
                let errorCents = (midiNumberExact - Double(midiNumberRounded)) * 100.0
                
                return (note, errorCents)
        }
}
