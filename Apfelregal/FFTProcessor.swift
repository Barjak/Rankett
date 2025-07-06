import Foundation
import SwiftUICore
import Accelerate
import CoreML

final class FFTProcessor {
        let fftSize: Int
        let halfSize: Int
        private let log2n: vDSP_Length
        
        private let fftSetup: FFTSetupD
        
        private let splitReal: UnsafeMutablePointer<Double>
        private let splitImag: UnsafeMutablePointer<Double>
        private var splitComplex: DSPDoubleSplitComplex
        
        private let tempReal: UnsafeMutablePointer<Double>
        private let tempImag: UnsafeMutablePointer<Double>
        private var tempSplit: DSPDoubleSplitComplex
        
        private let windowBuffer: UnsafeMutablePointer<Double>
        private let windowedRealBuffer: UnsafeMutablePointer<Double>
        private let windowedImagBuffer: UnsafeMutablePointer<Double>
        private let magnitudeBuffer: UnsafeMutablePointer<Double>
        
        private let outputSpectrumBuffer: UnsafeMutablePointer<Double>
        private let outputFrequencyBuffer: UnsafeMutablePointer<Double>
        
        // Frequency caching
        private var lastSampleRate: Double? = nil
        private var lastBasebandFreq: Double? = nil
        private var lastIsBaseband: Bool = false
        
        // Hann window power compensation factor
        private let hannPowerScale: Double = 1.0 / 0.375
        
        init(fftSize: Int) {
                self.fftSize = fftSize
                self.halfSize = fftSize / 2
                self.log2n = vDSP_Length(log2(Double(fftSize)))
                
                guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
                        fatalError("Failed to create FFT setup")
                }
                self.fftSetup = setup
                
                self.splitReal = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                self.splitImag = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                self.splitReal.initialize(repeating: 0, count: fftSize)
                self.splitImag.initialize(repeating: 0, count: fftSize)
                self.splitComplex = DSPDoubleSplitComplex(realp: splitReal, imagp: splitImag)
                
                self.tempReal = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                self.tempImag = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                self.tempReal.initialize(repeating: 0, count: fftSize)
                self.tempImag.initialize(repeating: 0, count: fftSize)
                self.tempSplit = DSPDoubleSplitComplex(realp: tempReal, imagp: tempImag)
                
                self.windowBuffer = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                self.windowedRealBuffer = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                self.windowedImagBuffer = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                self.magnitudeBuffer = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                
                self.outputSpectrumBuffer = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                self.outputFrequencyBuffer = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                
                self.magnitudeBuffer.initialize(repeating: 0, count: fftSize)
                self.windowedImagBuffer.initialize(repeating: 0, count: fftSize)
                self.outputSpectrumBuffer.initialize(repeating: 0, count: fftSize)
                self.outputFrequencyBuffer.initialize(repeating: 0, count: fftSize)
                
                var windowSize = vDSP_Length(fftSize)
                vDSP_hann_windowD(windowBuffer, windowSize, Int32(vDSP_HANN_NORM))
        }
        
        deinit {
                vDSP_destroy_fftsetupD(fftSetup)
                splitReal.deallocate()
                splitImag.deallocate()
                tempReal.deallocate()
                tempImag.deallocate()
                windowBuffer.deallocate()
                windowedRealBuffer.deallocate()
                windowedImagBuffer.deallocate()
                magnitudeBuffer.deallocate()
                outputSpectrumBuffer.deallocate()
                outputFrequencyBuffer.deallocate()
        }
        
        func processFullSpectrum(samples: [Double], sampleRate: Double, applyWindow: Bool = false) -> (spectrum: ArraySlice<Double>, frequencies: ArraySlice<Double>) {
                let actualSampleCount = min(samples.count, fftSize)
                
                performComplexFFTInternal(
                        realData: samples,
                        imagData: nil,
                        actualSampleCount: actualSampleCount,
                        applyWindow: applyWindow
                )
                
                generateFullSpectrumFrequencies(sampleRate: sampleRate)
                convertToDBAndCopyResults()
                
                let spectrumSlice = outputSpectrumBuffer.withMemoryRebound(to: Double.self, capacity: halfSize) { ptr in
                        ArraySlice(UnsafeBufferPointer(start: ptr, count: halfSize))
                }
                let frequencySlice = outputFrequencyBuffer.withMemoryRebound(to: Double.self, capacity: halfSize) { ptr in
                        ArraySlice(UnsafeBufferPointer(start: ptr, count: halfSize))
                }
                
                return (spectrumSlice, frequencySlice)
        }
        
        func processBaseband(samples: [DSPDoubleComplex],
                             basebandFreq: Double,
                             decimatedRate: Double,
                             applyWindow: Bool = true) -> (spectrum: ArraySlice<Double>, frequencies: ArraySlice<Double>) {
                
                let realData = samples.map { $0.real }
                let imagData = samples.map { $0.imag }
                let actualSampleCount = min(samples.count, fftSize)
                
                performComplexFFTInternal(
                        realData: realData,
                        imagData: imagData,
                        actualSampleCount: actualSampleCount,
                        applyWindow: applyWindow
                )
                
                generateBasebandFrequencies(basebandFreq: basebandFreq, sampleRate: decimatedRate)
                convertToDBAndCopyResults()
                reorderBasebandSpectrum()
                
                let spectrumSlice = outputSpectrumBuffer.withMemoryRebound(to: Double.self, capacity: fftSize) { ptr in
                        ArraySlice(UnsafeBufferPointer(start: ptr, count: fftSize))
                }
                let frequencySlice = outputFrequencyBuffer.withMemoryRebound(to: Double.self, capacity: fftSize) { ptr in
                        ArraySlice(UnsafeBufferPointer(start: ptr, count: fftSize))
                }
                
                return (spectrumSlice, frequencySlice)
        }
        
        private func performComplexFFTInternal(realData: [Double],
                                               imagData: [Double]?,
                                               actualSampleCount: Int,
                                               applyWindow: Bool) {
                
                let samplesToUse = min(realData.count, fftSize)
                
                if samplesToUse < fftSize {
                        memcpy(windowedRealBuffer, realData, samplesToUse * MemoryLayout<Double>.size)
                        memset(windowedRealBuffer + samplesToUse, 0, (fftSize - samplesToUse) * MemoryLayout<Double>.size)
                } else {
                        memcpy(windowedRealBuffer, realData, fftSize * MemoryLayout<Double>.size)
                }
                
                if let imagData = imagData {
                        if samplesToUse < fftSize {
                                memcpy(windowedImagBuffer, imagData, samplesToUse * MemoryLayout<Double>.size)
                                memset(windowedImagBuffer + samplesToUse, 0, (fftSize - samplesToUse) * MemoryLayout<Double>.size)
                        } else {
                                memcpy(windowedImagBuffer, imagData, fftSize * MemoryLayout<Double>.size)
                        }
                } else {
                        memset(windowedImagBuffer, 0, fftSize * MemoryLayout<Double>.size)
                }
                
                if applyWindow {
                        vDSP_vmulD(windowedRealBuffer, 1, windowBuffer, 1, windowedRealBuffer, 1, vDSP_Length(fftSize))
                        if imagData != nil {
                                vDSP_vmulD(windowedImagBuffer, 1, windowBuffer, 1, windowedImagBuffer, 1, vDSP_Length(fftSize))
                        }
                }
                
                splitComplex.realp.update(from: windowedRealBuffer, count: fftSize)
                splitComplex.imagp.update(from: windowedImagBuffer, count: fftSize)
                
                vDSP_fft_zriptD(
                        fftSetup,
                        &splitComplex,
                        1,
                        &tempSplit,
                        log2n,
                        FFTDirection(FFT_FORWARD)
                )
                
                vDSP_zvmagsD(&splitComplex, 1, magnitudeBuffer, 1, vDSP_Length(fftSize))
                
                var scaleFactor: Double = applyWindow ? hannPowerScale / Double(actualSampleCount) : 1.0 / Double(actualSampleCount)
                vDSP_vsmulD(magnitudeBuffer, 1, &scaleFactor, magnitudeBuffer, 1, vDSP_Length(fftSize))
                
                var count_int = Int32(fftSize)
                vvsqrt(magnitudeBuffer, magnitudeBuffer, &count_int)
        }
        
        private func generateFullSpectrumFrequencies(sampleRate: Double) {
                guard lastSampleRate != sampleRate || lastIsBaseband != false else { return }
                
                let binWidth = sampleRate / Double(fftSize)
                for i in 0..<fftSize {
                        outputFrequencyBuffer[i] = Double(i) * binWidth
                }
                
                lastSampleRate = sampleRate
                lastIsBaseband = false
        }
        
        private func generateBasebandFrequencies(basebandFreq: Double, sampleRate: Double) {
                guard lastSampleRate != sampleRate || lastBasebandFreq != basebandFreq || lastIsBaseband != true else { return }
                
                let binWidth = sampleRate / Double(fftSize)
                
                for i in 0..<fftSize {
                        if i <= halfSize {
                                outputFrequencyBuffer[i] = basebandFreq + Double(i) * binWidth
                        } else {
                                outputFrequencyBuffer[i] = basebandFreq + Double(i - fftSize) * binWidth
                        }
                }
                
                lastSampleRate = sampleRate
                lastBasebandFreq = basebandFreq
                lastIsBaseband = true
        }
        
        private func convertToDBAndCopyResults() {
                memcpy(outputSpectrumBuffer, magnitudeBuffer, fftSize * MemoryLayout<Double>.size)
                
                var floorDB: Double = 1e-10
                var ceilingDB: Double = .greatestFiniteMagnitude
                vDSP_vclipD(outputSpectrumBuffer, 1, &floorDB, &ceilingDB, outputSpectrumBuffer, 1, vDSP_Length(fftSize))
                
                var reference: Double = 1.0
                vDSP_vdbconD(outputSpectrumBuffer, 1, &reference, outputSpectrumBuffer, 1, vDSP_Length(fftSize), 1)
        }
        
        private func reorderBasebandSpectrum() {
                let tempBuffer = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                defer { tempBuffer.deallocate() }
                
                memcpy(tempBuffer, outputSpectrumBuffer, fftSize * MemoryLayout<Double>.size)
                
                for i in 0..<halfSize {
                        outputSpectrumBuffer[i] = tempBuffer[i + halfSize]
                        outputSpectrumBuffer[i + halfSize] = tempBuffer[i]
                }
                
                memcpy(tempBuffer, outputFrequencyBuffer, fftSize * MemoryLayout<Double>.size)
                for i in 0..<halfSize {
                        outputFrequencyBuffer[i] = tempBuffer[i + halfSize]
                        outputFrequencyBuffer[i + halfSize] = tempBuffer[i]
                }
        }
}
