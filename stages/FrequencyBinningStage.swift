import Foundation

class FrequencyBinningStage: ProcessingStage {
    typealias Input = [SpectralData]
    typealias Output = [SpectralData]
    
    private let outputBinCount: Int
    private let useLogScale: Bool
    private let minFrequency: Double
    private let maxFrequency: Double
    private var frequencyBinMap: [Int] = []
    private var binnedFrequencies: [Float] = []
    
    init(outputBinCount: Int, useLogScale: Bool, minFrequency: Double, maxFrequency: Double) {
        self.outputBinCount = outputBinCount
        self.useLogScale = useLogScale
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
    }
    
    func process(_ input: [SpectralData]) -> [SpectralData] {
        return input.map { spectralData in
            // Lazy initialization of frequency mapping
            if frequencyBinMap.isEmpty {
                createFrequencyMapping(spectralData: spectralData)
            }
            
            return applyBinning(to: spectralData)
        }
    }
    
    private func createFrequencyMapping(spectralData: SpectralData) {
        let frequencyResolution = spectralData.sampleRate / Double(spectralData.frequencies.count * 2)
        let nyquist = spectralData.sampleRate / 2.0
        
        if useLogScale {
            // Logarithmic frequency binning
            let logMin = log10(minFrequency)
            let logMax = log10(min(maxFrequency, nyquist))
            
            frequencyBinMap = (0..<outputBinCount).map { i in
                let logFreq = logMin + (logMax - logMin) * Double(i) / Double(outputBinCount - 1)
                let freq = pow(10, logFreq)
                let binIndex = Int(freq / frequencyResolution)
                return min(binIndex, spectralData.frequencies.count - 1)
            }
            
            // Calculate actual frequencies for each output bin
            binnedFrequencies = (0..<outputBinCount).map { i in
                let logFreq = logMin + (logMax - logMin) * Double(i) / Double(outputBinCount - 1)
                return Float(pow(10, logFreq))
            }
        } else {
            // Linear frequency binning
            let linearStep = (maxFrequency - minFrequency) / Double(outputBinCount - 1)
            
            frequencyBinMap = (0..<outputBinCount).map { i in
                let freq = minFrequency + Double(i) * linearStep
                let binIndex = Int(freq / frequencyResolution)
                return min(binIndex, spectralData.frequencies.count - 1)
            }
            
            binnedFrequencies = (0..<outputBinCount).map { i in
                Float(minFrequency + Double(i) * linearStep)
            }
        }
    }
    
    private func applyBinning(to spectralData: SpectralData) -> SpectralData {
        var binnedMagnitudes = [Float](repeating: -80, count: outputBinCount)
        
        for i in 0..<outputBinCount {
            let binIndex = frequencyBinMap[i]
            if binIndex < spectralData.magnitudes.count {
                binnedMagnitudes[i] = spectralData.magnitudes[binIndex]
            }
        }
        
        return SpectralData(
            magnitudes: binnedMagnitudes,
            frequencies: binnedFrequencies,
            sampleRate: spectralData.sampleRate
        )
    }
}
