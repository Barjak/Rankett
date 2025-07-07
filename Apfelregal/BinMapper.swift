// BinMapper.swift

import Foundation
import Accelerate

final class BinMapper {
        let binCount: Int
        let halfSize: Int
        let useLogScale: Bool
        let smoothingFactor: Double
        private let heterodyneOffset: Double
        
        private let lowIndices: [Int]
        private let highIndices: [Int]
        private let fractions: [Double]
        
        private let outputBuffer: UnsafeMutablePointer<Double>
        private let frequencyBuffer: UnsafeMutablePointer<Double>
        
        init(binCount: Int,
             halfSize: Int,
             sampleRate: Double,
             useLogScale: Bool,
             minFreq: Double,
             maxFreq: Double,
             heterodyneOffset: Double = 0,
             smoothingFactor: Double = 0.0) {
                
                self.binCount = binCount
                self.halfSize = halfSize
                self.useLogScale = useLogScale
                self.smoothingFactor = smoothingFactor
                self.heterodyneOffset = heterodyneOffset
                
                self.outputBuffer = UnsafeMutablePointer<Double>.allocate(capacity: binCount)
                self.frequencyBuffer = UnsafeMutablePointer<Double>.allocate(capacity: binCount)
                self.outputBuffer.initialize(repeating: -80.0, count: binCount)
                
                var lowIndices = [Int](repeating: 0, count: binCount)
                var highIndices = [Int](repeating: 0, count: binCount)
                var fractions = [Double](repeating: 0, count: binCount)
                
                let nyquist = sampleRate / 2.0
                let isBaseband = heterodyneOffset != 0
                let effectiveFFTSize = isBaseband ? halfSize : halfSize * 2
                let freqRes = sampleRate / Double(effectiveFFTSize)
                
                if useLogScale {
                        let logMin = log10(minFreq)
                        let logMax = log10(min(maxFreq, nyquist + heterodyneOffset))
                        let logRange = logMax - logMin
                        
                        for i in 0..<binCount {
                                let t = Double(i) / Double(binCount - 1)
                                let logFreq = logMin + logRange * t
                                let displayFreq = pow(10, logFreq)
                                frequencyBuffer[i] = displayFreq
                                
                                let inputFreq = displayFreq - heterodyneOffset
                                let binF: Double
                                
                                if isBaseband {
                                        binF = (inputFreq + nyquist) / freqRes
                                } else {
                                        binF = inputFreq / freqRes
                                }
                                
                                let low = Int(floor(binF))
                                let high = min(low + 1, halfSize - 1)
                                let fraction = binF - Double(low)
                                
                                lowIndices[i] = min(max(low, 0), halfSize - 1)
                                highIndices[i] = high
                                fractions[i] = fraction
                        }
                } else {
                        for i in 0..<binCount {
                                let normalizedPos = Double(i) / Double(binCount - 1)
                                let displayFreq = minFreq + normalizedPos * (maxFreq - minFreq)
                                frequencyBuffer[i] = displayFreq
                                
                                let inputFreq = displayFreq - heterodyneOffset
                                let binF: Double
                                
                                if isBaseband {
                                        binF = (inputFreq + nyquist) / freqRes
                                } else {
                                        binF = inputFreq / freqRes
                                }
                                
                                let low = Int(floor(binF))
                                let high = min(low + 1, halfSize - 1)
                                let fraction = binF - Double(low)
                                
                                lowIndices[i] = min(max(low, 0), halfSize - 1)
                                highIndices[i] = high
                                fractions[i] = fraction
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
                        for i in 0..<binCount {
                                outputBuffer[i] = outputBuffer[i] * smoothingFactor + (-80.0) * (1 - smoothingFactor)
                        }
                        return ArraySlice(UnsafeBufferPointer(start: outputBuffer, count: binCount))
                }
                
                let inputArray = Array(input)
                
                for i in 0..<binCount {
                        let low = lowIndices[i]
                        let high = highIndices[i]
                        let fraction = fractions[i]
                        
                        let newValue = (1 - fraction) * inputArray[low] + fraction * inputArray[high]
                        outputBuffer[i] = outputBuffer[i] * smoothingFactor + newValue * (1 - smoothingFactor)
                }
                
                return ArraySlice(UnsafeBufferPointer(start: outputBuffer, count: binCount))
        }
        
        var frequencies: ArraySlice<Double> {
                ArraySlice(UnsafeBufferPointer(start: frequencyBuffer, count: binCount))
        }
}
