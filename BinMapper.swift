// BinMapper.swift
import Foundation

final class BinMapper {
        private let config: AnalyzerConfig
        private let binCount: Int
        private let halfSize: Int
        
        // Pre-computed mapping for log scale
        private let logBinIndices: [(low: Int, high: Int, fraction: Float)]
        
        init(config: AnalyzerConfig, halfSize: Int) {
                self.config = config
                self.halfSize = halfSize
                self.binCount = config.fft.outputBinCount
                
                let binCount = self.binCount
                let halfSize = self.halfSize
                let useLog   = config.rendering.useLogFrequencyScale
                
                // these only depend on locals, never on self
                let indices: [(low: Int, high: Int, fraction: Float)]
                if useLog {
                        let nyquist  = config.audio.nyquistFrequency
                        let freqRes  = config.fft.frequencyResolution
                        let logMin   = log10(config.rendering.minFrequency)
                        let logMax   = log10(min(config.rendering.maxFrequency, nyquist))
                        
                        indices = (0..<binCount).map { i in
                                let t       = Float(i) / Float(binCount - 1)
                                let logFreq = logMin + (logMax - logMin) * Double(t)
                                let freq    = pow(10, logFreq)
                                let binF    = Float(freq / freqRes)
                                
                                let low     = Int(floor(binF))
                                let high    = min(low + 1, halfSize - 1)
                                let fraction = binF - Float(low)
                                return (low, high, fraction)
                        }
                } else {
                        indices = (0..<binCount).map { i in
                                let binF     = Float(i) * Float(halfSize - 1) / Float(binCount - 1)
                                let low      = Int(floor(binF))
                                let high     = min(low + 1, halfSize - 1)
                                let fraction = binF - Float(low)
                                return (low, high, fraction)
                        }
                }
                
                // 3) Now we can safely assign
                self.logBinIndices = indices
        }
        
        /// Map input spectrum to output bins using pre-computed indices
        func mapSpectrum(_ input: [Float]) -> [Float] {
                guard input.count >= halfSize else { return [] }
                
                var output = [Float](repeating: -80.0, count: binCount)
                
                for (i, mapping) in logBinIndices.enumerated() {
                        // Linear interpolation between bins
                        let value = (1 - mapping.fraction) * input[mapping.low] +
                        mapping.fraction * input[mapping.high]
                        output[i] = value
                }
                
                return output
        }
        
        /// Get frequency for each output bin
        var binFrequencies: [Float] {
                if config.rendering.useLogFrequencyScale {
                        let logMin = log10(config.rendering.minFrequency)
                        let logMax = log10(min(config.rendering.maxFrequency, config.audio.nyquistFrequency))
                        
                        return (0..<binCount).map { i in
                                let t = Float(i) / Float(binCount - 1)
                                let logFreq = logMin + (logMax - logMin) * Double(t)
                                return Float(pow(10, logFreq))
                        }
                } else {
                        let maxFreq = Float(config.audio.nyquistFrequency)
                        return (0..<binCount).map { i in
                                Float(i) * maxFreq / Float(binCount - 1)
                        }
                }
        }
}
