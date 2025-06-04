import SwiftUI
import Combine
import Foundation

// MARK: - Enums and Supporting Types

enum EndCorrectionAlgorithm: String, CaseIterable {
        case naive = "Naive"
        case rayleigh = "Rayleigh's Simple Rule-of-Thumb"
        case parvs = "PARVS Model"
        case levineSchwinger = "Levine & Schwinger Series #1"
        case morseIngard = "Morse & Ingard First-Order"
        case ingardEmpirical = "Ingard's Empirical Polynomial"
        case nomuraTsukamoto = "Nomura & Tsukamoto Polynomial"
        case flanged = "Flanged Pipe Expansion"
        case partialFlange = "Partial Flange"
        case ingardThickWall = "Ingard's Thick-Wall"
        case nakamuraUeda = "Nakamura & Ueda Thick-Wall"
        case directNumerical = "Direct Numerical Integration"
}

enum NumericalDisplayMode: String, CaseIterable {
        case cents = "Cents"
        case beat = "Beat"
        case errorHz = "Error (Hz)"
        case targetHz = "Target (Hz)"
        case actualHz = "Actual (Hz)"
        case theoreticalLength = "Pipe Length (Naive)"
        case lengthCorrectionNaive = "Length Correction (Naive)"
        case amplitudeBar = "Amplitude"
        case finePitchBar = "Fine Pitch"
}

enum Temperament: String, CaseIterable {
        case equal = "Equal"
        case justIntonation = "Just Intonation"
        case pythagorean = "Pythagorean"
        case meantone = "Meantone"
        case werkmeister = "Werkmeister III"
        case valotti = "Valotti"
}

struct Instrument: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let overtoneProfile: [Double] // Relative magnitudes for overtones 1-8
        let pipeScale: Double // Diameter in mm
        let wallThickness: Double // in mm
}

// MARK: - Tuning Parameter Store

class TuningParameterStore: ObservableObject {
        @Published var concertPitch: Double = 440.0
        @Published var targetPitch: Double = 440.0
        @Published var targetPartial: Int = 1
        @Published var overtoneProfile: [Double] = [1.0, 0.5, 0.33, 0.25, 0.2, 0.17, 0.14, 0.125]
        @Published var pipeScale: Double = 138.0 // mm
        @Published var wallThickness: Double = 0.0 // mm
        @Published var endCorrectionAlgorithm: EndCorrectionAlgorithm = .naive
        @Published var temperament: Temperament = .equal
        @Published var gateTime: Double = 100.0 // milliseconds
        @Published var audibleToneEnabled: Bool = false
        @Published var pitchIncrementSemitones: Int = 1
        @Published var mutationStopTranspose: Int = 0
        
        @Published var leftDisplayMode: NumericalDisplayMode = .cents
        @Published var rightDisplayMode: NumericalDisplayMode = .errorHz
        
        @Published var selectedInstrument: Instrument = Instrument(
                name: "Principal 8'",
                overtoneProfile: [1.0, 0.5, 0.33, 0.25, 0.2, 0.17, 0.14, 0.125],
                pipeScale: 138.0,
                wallThickness: 0.0
        )
        
        // Calculated properties
        var actualPitch: Double = 440.0 // This would come from the audio processor
        
        var centsError: Double {
                1200 * log2(actualPitch / targetPitch)
        }
        
        var beatFrequency: Double {
                abs(actualPitch - targetPitch)
        }
}
