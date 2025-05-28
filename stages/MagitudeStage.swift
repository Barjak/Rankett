import Foundation
import Accelerate

class MagnitudeStage: ProcessingStage {
    typealias Input = [SpectralData]
    typealias Output = [SpectralData]
    
    private let convertToDb: Bool
    private let dbFloor: Float
    
    init(convertToDb: Bool = true, dbFloor: Float = 1e-10) {
        self.convertToDb = convertToDb
        self.dbFloor = dbFloor
    }
    
    func process(_ input: [SpectralData]) -> [SpectralData] {
        guard convertToDb else { return input }  // Pass through if not converting
        
        return input.map { spectralData in
            let dbMagnitudes = spectralData.magnitudes.map { magnitude in
                20 * log10(max(magnitude, dbFloor))
            }
            
            return SpectralData(
                magnitudes: dbMagnitudes,
                frequencies: spectralData.frequencies,
                sampleRate: spectralData.sampleRate
            )
        }
    }
}
