// BinMapper.swift
import Foundation

final class BinMapper {
        private let store: TuningParameterStore
        private let binCount: Int
        private let halfSize: Int
        
        // Pre-computed mapping for log scale
        private let logBinIndices: [(low: Int, high: Int, fraction: Float)]
        
        init(store: TuningParameterStore, halfSize: Int) {
                self.store = store
                self.halfSize = halfSize
                self.binCount = store.downscaleBinCount
                
                let binCount = self.binCount
                let halfSize = self.halfSize
                let useLog   = store.renderWithLogFrequencyScale
                
                // these only depend on locals, never on self
                let indices: [(low: Int, high: Int, fraction: Float)]
                if useLog {
                        let nyquist  = store.nyquistFrequency
                        let freqRes  = store.frequencyResolution
                        let logMin   = log10(store.renderMinFrequency)
                        let logMax   = log10(min(store.renderMaxFrequency, nyquist))
                        
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
        
        func mapHPSSpectrum(_ hpsSpectrum: [Float]) -> [Float] {
                guard !hpsSpectrum.isEmpty else { return [] }
                
                var output = [Float](repeating: -80.0, count: binCount)
                
                // HPS spectrum has same bin width as original FFT
                let hpsMaxIndex = hpsSpectrum.count - 1
                
                for (i, mapping) in logBinIndices.enumerated() {
                        // Check if this bin's frequency is within HPS spectrum range
                        if mapping.low <= hpsMaxIndex {
                                if mapping.high <= hpsMaxIndex {
                                        // Both bins are within range, interpolate normally
                                        let value = (1 - mapping.fraction) * hpsSpectrum[mapping.low] +
                                        mapping.fraction * hpsSpectrum[mapping.high]
                                        output[i] = value
                                } else {
                                        // Only low bin is within range, use it directly
                                        output[i] = hpsSpectrum[mapping.low]
                                }
                        }
                        // If both bins are out of range, leave as -80.0
                }
                
                return output
        }
        
        /// Get frequency for each output bin
        var binFrequencies: [Float] {
                if store.renderWithLogFrequencyScale {
                        let logMin = log10(store.renderMinFrequency)
                        let logMax = log10(min(store.renderMaxFrequency, store.nyquistFrequency))
                        
                        return (0..<binCount).map { i in
                                let t = Float(i) / Float(binCount - 1)
                                let logFreq = logMin + (logMax - logMin) * Double(t)
                                return Float(pow(10, logFreq))
                        }
                } else {
                        let maxFreq = Float(store.nyquistFrequency)
                        return (0..<binCount).map { i in
                                Float(i) * maxFreq / Float(binCount - 1)
                        }
                }
        }
}
