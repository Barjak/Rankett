import Foundation
import Accelerate

final class BinMapper {
        let binCount: Int
        let halfSize: Int
        let useLogScale: Bool
        
        // Pre-computed mapping indices
        private let lowIndices: [Int]
        private let highIndices: [Int]
        private let fractions: [Double]
        
        // Pre-allocated buffers
        private let outputBuffer: UnsafeMutablePointer<Double>
        private let frequencyBuffer: UnsafeMutablePointer<Double>
        
        init(binCount: Int,
             halfSize: Int,
             sampleRate: Double,
             useLogScale: Bool,
             minFreq: Double,
             maxFreq: Double) {
                
                self.binCount = binCount
                self.halfSize = halfSize
                self.useLogScale = useLogScale
                
                // Allocate buffers
                self.outputBuffer = UnsafeMutablePointer<Double>.allocate(capacity: binCount)
                self.frequencyBuffer = UnsafeMutablePointer<Double>.allocate(capacity: binCount)
                
                // Pre-compute mapping indices and frequencies
                var lowIndices = [Int](repeating: 0, count: binCount)
                var highIndices = [Int](repeating: 0, count: binCount)
                var fractions = [Double](repeating: 0, count: binCount)
                
                let nyquist = sampleRate / 2.0
                let freqRes = sampleRate / Double(halfSize * 2)
                
                if useLogScale {
                        let logMin = log10(minFreq)
                        let logMax = log10(min(maxFreq, nyquist))
                        let logRange = logMax - logMin
                        
                        for i in 0..<binCount {
                                let t = Double(i) / Double(binCount - 1)
                                let logFreq = logMin + logRange * t
                                let freq = pow(10, logFreq)
                                let binF = freq / freqRes
                                
                                let low = Int(floor(binF))
                                let high = min(low + 1, halfSize - 1)
                                let fraction = binF - Double(low)
                                
                                lowIndices[i] = min(max(low, 0), halfSize - 1)
                                highIndices[i] = high
                                fractions[i] = fraction
                                frequencyBuffer[i] = freq
                        }
                } else {
                        let maxBinF = Double(halfSize - 1)
                        
                        for i in 0..<binCount {
                                let binF = Double(i) * maxBinF / Double(binCount - 1)
                                let low = Int(floor(binF))
                                let high = min(low + 1, halfSize - 1)
                                let fraction = binF - Double(low)
                                
                                lowIndices[i] = low
                                highIndices[i] = high
                                fractions[i] = fraction
                                frequencyBuffer[i] = Double(i) * nyquist / Double(binCount - 1)
                        }
                }
                
                self.lowIndices = lowIndices
                self.highIndices = highIndices
                self.fractions = fractions
        }
        
        deinit {
                outputBuffer.deallocate()
                frequencyBuffer.deallocate()
        }
        
        func mapSpectrum(_ input: ArraySlice<Double>) -> ArraySlice<Double> {
                guard input.count >= halfSize else {
                        outputBuffer.initialize(repeating: -80.0, count: binCount)
                        return ArraySlice(UnsafeBufferPointer(start: outputBuffer, count: binCount))
                }
                
                // Convert input slice to contiguous array for safe indexing
                let inputArray = Array(input)
                
                for i in 0..<binCount {
                        let low = lowIndices[i]
                        let high = highIndices[i]
                        let fraction = fractions[i]
                        
                        outputBuffer[i] = (1 - fraction) * inputArray[low] + fraction * inputArray[high]
                }
                
                return ArraySlice(UnsafeBufferPointer(start: outputBuffer, count: binCount))
        }
        
        var frequencies: ArraySlice<Double> {
                ArraySlice(UnsafeBufferPointer(start: frequencyBuffer, count: binCount))
        }
}
