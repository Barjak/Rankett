import Foundation
import Accelerate

final class BinMapper {
        let binCount: Int
        private(set) var halfSize: Int
        private(set) var sampleRate: Double
        private(set) var useLogScale: Bool
        let smoothingFactor: Double
        
        private(set) var minFreq: Double
        private(set) var maxFreq: Double
        private(set) var heterodyneOffset: Double
        
        
        private var lowIndices: [Int]
        private var highIndices: [Int]
        private var fractions: [Double]
        
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
                
                precondition(binCount > 0)
                precondition(halfSize > 0)
                precondition(sampleRate > 0)
                precondition(minFreq > 0 && minFreq < maxFreq)
                
                self.binCount = binCount
                self.halfSize = halfSize
                self.sampleRate = sampleRate
                self.useLogScale = useLogScale
                self.smoothingFactor = smoothingFactor
                
                self.minFreq = 0
                self.maxFreq = 0
                self.heterodyneOffset = 0
                
                self.lowIndices = Array(repeating: 0, count: binCount)
                self.highIndices = Array(repeating: 0, count: binCount)
                self.fractions = Array(repeating: 0, count: binCount)
                
                self.outputBuffer = UnsafeMutablePointer<Double>.allocate(capacity: binCount)
                self.frequencyBuffer = UnsafeMutablePointer<Double>.allocate(capacity: binCount)
                self.outputBuffer.initialize(repeating: -80.0, count: binCount)
                
                remap(minFreq: minFreq,
                      maxFreq: maxFreq,
                      heterodyneOffset: heterodyneOffset,
                      sampleRate: sampleRate,
                      halfSize: halfSize,
                      useLogScale: true)
        }
        
        deinit {
                outputBuffer.deallocate()
                frequencyBuffer.deallocate()
        }
        
        func remap(minFreq: Double,
                   maxFreq: Double,
                   heterodyneOffset: Double,
                   sampleRate: Double,
                   halfSize: Int,
                   useLogScale: Bool) {
                
                precondition(minFreq > 0 && minFreq < maxFreq)
                precondition(halfSize > 0)
                precondition(sampleRate > 0)
                
                let needsArrayResize = self.halfSize != halfSize
                
                guard self.minFreq != minFreq ||
                        self.maxFreq != maxFreq ||
                        self.heterodyneOffset != heterodyneOffset ||
                        self.sampleRate != sampleRate ||
                        self.halfSize != halfSize ||
                        self.useLogScale != useLogScale else {
                        return
                }
                
                self.minFreq = minFreq
                self.maxFreq = maxFreq
                self.heterodyneOffset = heterodyneOffset
                self.sampleRate = sampleRate
                self.halfSize = halfSize
                self.useLogScale = useLogScale
                
                if needsArrayResize {
                        lowIndices = Array(repeating: 0, count: binCount)
                        highIndices = Array(repeating: 0, count: binCount)
                        fractions = Array(repeating: 0, count: binCount)
                }
                
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
                                
                                computeIndices(displayFreq: displayFreq,
                                               heterodyneOffset: heterodyneOffset,
                                               freqRes: freqRes,
                                               nyquist: nyquist,
                                               isBaseband: isBaseband,
                                               index: i)
                        }
                } else {
                        let freqRange = maxFreq - minFreq
                        
                        for i in 0..<binCount {
                                let t = Double(i) / Double(binCount - 1)
                                let displayFreq = minFreq + t * freqRange
                                frequencyBuffer[i] = displayFreq
                                
                                computeIndices(displayFreq: displayFreq,
                                               heterodyneOffset: heterodyneOffset,
                                               freqRes: freqRes,
                                               nyquist: nyquist,
                                               isBaseband: isBaseband,
                                               index: i)
                        }
                }
        }
        
        private func computeIndices(displayFreq: Double,
                                    heterodyneOffset: Double,
                                    freqRes: Double,
                                    nyquist: Double,
                                    isBaseband: Bool,
                                    index: Int) {
                let inputFreq = displayFreq - heterodyneOffset
                
                let binF: Double
                if isBaseband {
                        // For baseband, negative frequencies are in the first half after reordering
                        if inputFreq < 0 {
                                binF = (inputFreq + sampleRate) / freqRes
                        } else {
                                binF = inputFreq / freqRes
                        }
                } else {
                        binF = inputFreq / freqRes
                }
                
                let low = Int(floor(binF))
                let high = low + 1
                let fraction = binF - Double(low)
                
                lowIndices[index] = max(0, min(low, halfSize - 1))
                highIndices[index] = max(0, min(high, halfSize - 1))
                fractions[index] = lowIndices[index] == highIndices[index] ? 0 : fraction
        }
        
        func mapSpectrum(_ input: ArraySlice<Double>) -> ArraySlice<Double> {
                guard input.count >= halfSize else {
                        vDSP_vsmulD(outputBuffer, 1, [smoothingFactor], outputBuffer, 1, vDSP_Length(binCount))
                        var fadeValue = -80.0 * (1 - smoothingFactor)
                        vDSP_vsaddD(outputBuffer, 1, &fadeValue, outputBuffer, 1, vDSP_Length(binCount))
                        return ArraySlice(UnsafeBufferPointer(start: outputBuffer, count: binCount))
                }
                
                input.withUnsafeBufferPointer { inputBuffer in
                        let inputPtr = inputBuffer.baseAddress!
                        
                        for i in 0..<binCount {
                                let low = lowIndices[i]
                                let high = highIndices[i]
                                let fraction = fractions[i]
                                
                                let newValue = (1 - fraction) * inputPtr[low] + fraction * inputPtr[high]
                                outputBuffer[i] = outputBuffer[i] * smoothingFactor + newValue * (1 - smoothingFactor)
                        }
                }
                
                return ArraySlice(UnsafeBufferPointer(start: outputBuffer, count: binCount))
        }
        
        var frequencies: ArraySlice<Double> {
                ArraySlice(UnsafeBufferPointer(start: frequencyBuffer, count: binCount))
        }
}
