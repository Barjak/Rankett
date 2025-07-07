import Foundation
import Accelerate

class StreamingPreprocessor {
        let fsOrig: Double
        let fBaseband: Double
        let marginCents: Double
        let attenDB: Double
        
        let bandwidth: Double
        let decimationFactor: Int
        let fsOut: Double
        
        let sosCoefficients: [[Double]]
        let sectionCount: Int
        var biquadSetup: vDSP_biquad_SetupD?
        var delayReal: [Double]
        var delayImag: [Double]
        
        private var phaseAccumulator: Double = 0.0
        private let omega: Double
        private var iirSampleCount: Int = 0
        
        private var heterodyneSplitBuffer: DSPDoubleSplitComplex
        private var iirOutputSplitBuffer: DSPDoubleSplitComplex
        private let maxBufferSize = 16384
        
        init(fsOrig: Double, fBaseband: Double, marginCents: Double = 50, attenDB: Double = 30) {
                precondition(marginCents > 1, "Margin must be greater than 1 cent")
                precondition(fBaseband < fsOrig / 2, "Baseband frequency must be less than Nyquist")
                precondition(fBaseband > 0, "Baseband frequency must be positive")
                
                self.fsOrig = fsOrig
                self.fBaseband = fBaseband
                self.marginCents = marginCents
                self.attenDB = attenDB
                
                let marginFactor = pow(2, marginCents / 1200)
                self.bandwidth = (fBaseband * marginFactor) - (fBaseband / marginFactor)
                
                let fsBBMin = 2.5 * bandwidth
                self.decimationFactor = max(1, Int(floor(fsOrig / (2 * fsBBMin))))
                self.fsOut = fsOrig / Double(decimationFactor)
                
                self.omega = 2 * .pi * fBaseband / fsOrig
                
                let (sos, sections) = StreamingPreprocessor.designButterworthFilter(
                        fsOrig: fsOrig,
                        decimationFactor: decimationFactor,
                        attenDB: attenDB
                )
                
                self.sosCoefficients = sos
                self.sectionCount = sections
                
                var coefficients: [Double] = []
                for section in sos {
                        coefficients.append(contentsOf: section)
                }
                self.biquadSetup = vDSP_biquad_CreateSetupD(coefficients, vDSP_Length(sections))
                
                let delayCount = 2 * sections + 2
                self.delayReal = Array(repeating: 0, count: delayCount)
                self.delayImag = Array(repeating: 0, count: delayCount)
                
                let realPtr1 = UnsafeMutablePointer<Double>.allocate(capacity: maxBufferSize)
                let imagPtr1 = UnsafeMutablePointer<Double>.allocate(capacity: maxBufferSize)
                heterodyneSplitBuffer = DSPDoubleSplitComplex(realp: realPtr1, imagp: imagPtr1)
                
                let realPtr2 = UnsafeMutablePointer<Double>.allocate(capacity: maxBufferSize)
                let imagPtr2 = UnsafeMutablePointer<Double>.allocate(capacity: maxBufferSize)
                iirOutputSplitBuffer = DSPDoubleSplitComplex(realp: realPtr2, imagp: imagPtr2)
        }
        
        deinit {
                if let setup = biquadSetup {
                        vDSP_biquad_DestroySetupD(setup)
                }
                heterodyneSplitBuffer.realp.deallocate()
                heterodyneSplitBuffer.imagp.deallocate()
                iirOutputSplitBuffer.realp.deallocate()
                iirOutputSplitBuffer.imagp.deallocate()
        }
        
        func process(samples: [Double]) -> [DSPDoubleComplex] {
                let count = samples.count
                guard count > 0 else { return [] }
                
                if count > maxBufferSize {
                        var result: [DSPDoubleComplex] = []
                        var offset = 0
                        while offset < count {
                                let chunkSize = min(maxBufferSize, count - offset)
                                let chunk = Array(samples[offset..<offset + chunkSize])
                                result.append(contentsOf: process(samples: chunk))
                                offset += chunkSize
                        }
                        return result
                }
                
                heterodyneToBaseband(samples: samples, output: heterodyneSplitBuffer, count: count)
                applyIIRFilter(input: heterodyneSplitBuffer, output: iirOutputSplitBuffer, count: count)
                return performDecimation(input: iirOutputSplitBuffer, inputCount: count)
        }
        
        func process(samples: [Float]) -> [DSPDoubleComplex] {
                var doubleSamples = [Double](repeating: 0, count: samples.count)
                vDSP_vspdp(samples, 1, &doubleSamples, 1, vDSP_Length(samples.count))
                return process(samples: doubleSamples)
        }
        
        func reset() {
                phaseAccumulator = 0.0
                iirSampleCount = 0
                delayReal = Array(repeating: 0, count: delayReal.count)
                delayImag = Array(repeating: 0, count: delayImag.count)
        }
        
        private func heterodyneToBaseband(samples: [Double], output: DSPDoubleSplitComplex, count: Int) {
                var phases = [Double](repeating: 0, count: count)
                var stride = omega
                var initialPhase = phaseAccumulator
                
                phases.withUnsafeMutableBufferPointer { phasesPtr in
                        vDSP_vrampD(&initialPhase, &stride, phasesPtr.baseAddress!, 1, vDSP_Length(count))
                }
                
                phaseAccumulator = remainder(phaseAccumulator + omega * Double(count), 2 * .pi)
                
                var sines = [Double](repeating: 0, count: count)
                var cosines = [Double](repeating: 0, count: count)
                var n = Int32(count)
                vvsincos(&sines, &cosines, &phases, &n)
                
                vDSP_vmulD(samples, 1, cosines, 1, output.realp, 1, vDSP_Length(count))
                
                var negativeOne = -1.0
                vDSP_vsmulD(samples, 1, &negativeOne, output.imagp, 1, vDSP_Length(count))
                vDSP_vmulD(output.imagp, 1, sines, 1, output.imagp, 1, vDSP_Length(count))
        }
        
        private func applyIIRFilter(input: DSPDoubleSplitComplex, output: DSPDoubleSplitComplex, count: Int) {
                guard let setup = biquadSetup else { return }
                vDSP_biquadD(setup, &delayReal, input.realp, 1, output.realp, 1, vDSP_Length(count))
                vDSP_biquadD(setup, &delayImag, input.imagp, 1, output.imagp, 1, vDSP_Length(count))
        }
        
        private func performDecimation(input: DSPDoubleSplitComplex, inputCount: Int) -> [DSPDoubleComplex] {
                guard decimationFactor > 1 else {
                        var result = [DSPDoubleComplex](repeating: DSPDoubleComplex(real: 0, imag: 0), count: inputCount)
                        for i in 0..<inputCount {
                                result[i] = DSPDoubleComplex(real: input.realp[i], imag: input.imagp[i])
                        }
                        return result
                }
                
                var decimatedSamples: [DSPDoubleComplex] = []
                decimatedSamples.reserveCapacity((inputCount + decimationFactor - 1) / decimationFactor)
                
                for i in 0..<inputCount {
                        if (iirSampleCount + i) % decimationFactor == 0 {
                                decimatedSamples.append(DSPDoubleComplex(real: input.realp[i], imag: input.imagp[i]))
                        }
                }
                
                iirSampleCount = (iirSampleCount + inputCount) % decimationFactor
                return decimatedSamples
        }
        
        private static func designButterworthFilter(fsOrig: Double, decimationFactor: Int, attenDB: Double) -> ([[Double]], Int) {
                let nyquist = fsOrig / 2
                let decimatedNyquist = fsOrig / (2 * Double(decimationFactor))
                let wp = 0.8 * decimatedNyquist / nyquist
                let ws = 1.0 * decimatedNyquist / nyquist
                
                let n = butterworthOrder(wp: wp, ws: ws, gpass: 0.5, gstop: attenDB)
                let (poles, gain) = butterworthAnalogPrototype(order: n)
                
                let wc = wp
                let scaledPoles = poles.map { DSPDoubleComplex(real: $0.real * wc, imag: $0.imag * wc) }
                
                let (zPoles, zGain) = bilinearTransform(poles: scaledPoles, zeros: [], gain: gain, fs: fsOrig)
                
                let sos = zpk2sos(zeros: Array(repeating: DSPDoubleComplex(real: -1, imag: 0), count: n),
                                  poles: zPoles,
                                  gain: zGain)
                
                return (sos, sos.count)
        }
        
        private static func butterworthOrder(wp: Double, ws: Double, gpass: Double, gstop: Double) -> Int {
                let wpw = tan(.pi * wp / 2)
                let wsw = tan(.pi * ws / 2)
                
                let gpassLinear = pow(10, gpass / 20)
                let gstopLinear = pow(10, gstop / 20)
                
                let num = log((pow(gstopLinear, 2) - 1) / (pow(gpassLinear, 2) - 1))
                let den = 2 * log(wsw / wpw)
                
                return Int(ceil(num / den))
        }
        
        private static func butterworthAnalogPrototype(order: Int) -> ([DSPDoubleComplex], Double) {
                var poles: [DSPDoubleComplex] = []
                
                for k in 0..<order {
                        let theta = .pi * (2 * Double(k) + 1) / (2 * Double(order)) + .pi / 2
                        poles.append(DSPDoubleComplex(real: cos(theta), imag: sin(theta)))
                }
                
                return (poles, 1.0)
        }
        
        private static func bilinearTransform(poles: [DSPDoubleComplex], zeros: [DSPDoubleComplex], gain: Double, fs: Double) -> ([DSPDoubleComplex], Double) {
                let fs2 = 2.0 * fs
                
                let zPoles = poles.map { p -> DSPDoubleComplex in
                        let num = DSPDoubleComplex(real: fs2 + p.real, imag: p.imag)
                        let den = DSPDoubleComplex(real: fs2 - p.real, imag: -p.imag)
                        return complexDivide(num, den)
                }
                
                let degree = poles.count - zeros.count
                
                var zGain = gain
                for p in poles {
                        zGain *= sqrt(pow(fs2 - p.real, 2) + pow(p.imag, 2))
                }
                zGain /= pow(fs2, Double(degree))
                
                return (zPoles, zGain)
        }
        
        private static func zpk2sos(zeros: [DSPDoubleComplex], poles: [DSPDoubleComplex], gain: Double) -> [[Double]] {
                var sections: [[Double]] = []
                var remainingPoles = poles
                var remainingZeros = zeros
                
                while remainingPoles.count >= 2 {
                        let p1 = remainingPoles.removeFirst()
                        
                        if let conjIndex = remainingPoles.firstIndex(where: { abs($0.real - p1.real) < 1e-6 && abs($0.imag + p1.imag) < 1e-6 }) {
                                let p2 = remainingPoles.remove(at: conjIndex)
                                
                                let z1 = remainingZeros.isEmpty ? DSPDoubleComplex(real: -1, imag: 0) : remainingZeros.removeFirst()
                                let z2 = remainingZeros.isEmpty ? DSPDoubleComplex(real: -1, imag: 0) : remainingZeros.removeFirst()
                                
                                let b0: Double = 1.0
                                let b1: Double = -(z1.real + z2.real)
                                let b2: Double = complexMultiply(z1, z2).real
                                
                                let a1: Double = -(p1.real + p2.real)
                                let a2: Double = complexMultiply(p1, p2).real
                                
                                sections.append([b0, b1, b2, a1, a2])
                        }
                }
                
                if !remainingPoles.isEmpty {
                        let p = remainingPoles.removeFirst()
                        let z = remainingZeros.isEmpty ? DSPDoubleComplex(real: -1, imag: 0) : remainingZeros.removeFirst()
                        sections.append([1.0, -z.real, 0, -p.real, 0])
                }
                
                if !sections.isEmpty {
                        sections[0][0] *= gain
                        sections[0][1] *= gain
                        sections[0][2] *= gain
                }
                
                return sections
        }
        
        private static func complexMultiply(_ a: DSPDoubleComplex, _ b: DSPDoubleComplex) -> DSPDoubleComplex {
                return DSPDoubleComplex(real: a.real * b.real - a.imag * b.imag,
                                        imag: a.real * b.imag + a.imag * b.real)
        }
        
        private static func complexDivide(_ a: DSPDoubleComplex, _ b: DSPDoubleComplex) -> DSPDoubleComplex {
                let denominator = b.real * b.real + b.imag * b.imag
                return DSPDoubleComplex(real: (a.real * b.real + a.imag * b.imag) / denominator,
                                        imag: (a.imag * b.real - a.real * b.imag) / denominator)
        }
}
