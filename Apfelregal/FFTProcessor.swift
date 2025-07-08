// FFTProcessor.swift

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
        private let amplitudeBuffer: UnsafeMutablePointer<Double>
        
        private let outputSpectrumBuffer: UnsafeMutablePointer<Double>
        private let outputFrequencyBuffer: UnsafeMutablePointer<Double>
        
        private var lastSampleRate: Double? = nil
        private var lastBasebandFreq: Double? = nil
        private var lastIsBaseband: Bool = false
        
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
                self.amplitudeBuffer = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                
                self.outputSpectrumBuffer = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                self.outputFrequencyBuffer = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                
                self.amplitudeBuffer.initialize(repeating: 0, count: fftSize)
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
                amplitudeBuffer.deallocate()
                outputSpectrumBuffer.deallocate()
                outputFrequencyBuffer.deallocate()
        }
        
        func processFullSpectrum(samples: [Double], sampleRate: Double, applyWindow: Bool = false) -> (spectrum: ArraySlice<Double>, frequencies: ArraySlice<Double>) {
                let actualSampleCount = min(samples.count, fftSize)
                
                performComplexFFT(
                        realData: samples,
                        imagData: nil,
                        actualSampleCount: actualSampleCount,
                        applyWindow: applyWindow
                )
                
                generateFullSpectrumFrequencies(sampleRate: sampleRate)
                normalizeAndConvertToDB(count: halfSize + 1, actualSampleCount: actualSampleCount, applyWindow: applyWindow, singleSided: true)
                
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
                
                performComplexFFT(
                        realData: realData,
                        imagData: imagData,
                        actualSampleCount: actualSampleCount,
                        applyWindow: applyWindow
                )
                
                generateBasebandFrequencies(basebandFreq: basebandFreq, sampleRate: decimatedRate)
                normalizeAndConvertToDB(count: fftSize, actualSampleCount: actualSampleCount, applyWindow: applyWindow, singleSided: false)
                reorderBasebandSpectrum()
                
                let spectrumSlice = outputSpectrumBuffer.withMemoryRebound(to: Double.self, capacity: fftSize) { ptr in
                        ArraySlice(UnsafeBufferPointer(start: ptr, count: fftSize))
                }
                let frequencySlice = outputFrequencyBuffer.withMemoryRebound(to: Double.self, capacity: fftSize) { ptr in
                        ArraySlice(UnsafeBufferPointer(start: ptr, count: fftSize))
                }
                
                return (spectrumSlice, frequencySlice)
        }
        
        private func performComplexFFT(realData: [Double],
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
                        vDSP_vmulD(windowedRealBuffer, 1, windowBuffer, 1, windowedRealBuffer, 1, vDSP_Length(samplesToUse))
                        if imagData != nil {
                                vDSP_vmulD(windowedImagBuffer, 1, windowBuffer, 1, windowedImagBuffer, 1, vDSP_Length(samplesToUse))
                        }
                }
                
                splitComplex.realp.update(from: windowedRealBuffer, count: fftSize)
                splitComplex.imagp.update(from: windowedImagBuffer, count: fftSize)
                
                vDSP_fft_ziptD(
                        fftSetup,
                        &splitComplex,
                        1,
                        &tempSplit,
                        log2n,
                        FFTDirection(FFT_FORWARD)
                )
                
                vDSP_zvabsD(&splitComplex, 1, amplitudeBuffer, 1, vDSP_Length(fftSize))
        }
        
        private func normalizeAndConvertToDB(count: Int, actualSampleCount: Int, applyWindow: Bool, singleSided: Bool) {
                
                var invL = 1.0 / Double(actualSampleCount)
                
                if applyWindow && actualSampleCount > 0 {
                        var windowSum: Double = 0
                        vDSP_sveD(windowBuffer, 1, &windowSum, vDSP_Length(actualSampleCount))
                        let coherentGain = windowSum / Double(actualSampleCount)
                        invL /= coherentGain
                }
                
                if singleSided {
                        amplitudeBuffer[0] *= invL
                        if halfSize < count {
                                amplitudeBuffer[halfSize] *= invL
                        }
                        
                        var twoInvL = 2.0 * invL
                        let nonDCCount = min(halfSize - 1, count - 1)
                        if nonDCCount > 0 {
                                vDSP_vsmulD(amplitudeBuffer + 1, 1, &twoInvL, amplitudeBuffer + 1, 1, vDSP_Length(nonDCCount))
                        }
                        
                        memcpy(outputSpectrumBuffer, amplitudeBuffer, count * MemoryLayout<Double>.size)
                } else {
                        vDSP_vsmulD(amplitudeBuffer, 1, &invL, outputSpectrumBuffer, 1, vDSP_Length(count))
                }
                print("Baseband normalization: actualSamples=\(actualSampleCount), fftSize=\(fftSize), invL=\(invL)")
                print("First few amplitudes before dB: ", amplitudeBuffer[0],  amplitudeBuffer[1], amplitudeBuffer[2], amplitudeBuffer[3])
                var floorDB: Double = 1e-10
                var ceilingDB: Double = .greatestFiniteMagnitude
                vDSP_vclipD(outputSpectrumBuffer, 1, &floorDB, &ceilingDB, outputSpectrumBuffer, 1, vDSP_Length(count))
                
                var reference: Double = 1.0
                vDSP_vdbconD(outputSpectrumBuffer, 1, &reference, outputSpectrumBuffer, 1, vDSP_Length(count), 1)
        }
        
        private func generateFullSpectrumFrequencies(sampleRate: Double) {
                guard lastSampleRate != sampleRate || lastIsBaseband != false else { return }
                
                let binWidth = sampleRate / Double(fftSize)
                for i in 0..<halfSize {
                        outputFrequencyBuffer[i] = Double(i) * binWidth
                }
                
                lastSampleRate = sampleRate
                lastIsBaseband = false
        }
        
        private func generateBasebandFrequencies(basebandFreq: Double, sampleRate: Double) {
                guard lastSampleRate != sampleRate || lastBasebandFreq != basebandFreq || lastIsBaseband != true else { return }
                
                let binWidth = sampleRate / Double(fftSize)
                
                for i in 0..<fftSize {
                        if i < halfSize {
                                outputFrequencyBuffer[i] = Double(i) * binWidth
                        } else {
                                outputFrequencyBuffer[i] = Double(i - fftSize) * binWidth
                        }
                }
                
                lastSampleRate = sampleRate
                lastBasebandFreq = basebandFreq
                lastIsBaseband = true
                print("Baseband freqs[0]=\(outputFrequencyBuffer[0]), freqs[\(halfSize)]=\(outputFrequencyBuffer[halfSize])")

        }
        
        private func reorderBasebandSpectrum() {
                let tempBuffer = UnsafeMutablePointer<Double>.allocate(capacity: fftSize)
                defer { tempBuffer.deallocate() }
                
                let needsReorder = outputFrequencyBuffer[0] >= 0
                guard needsReorder else { return }
                
                memcpy(tempBuffer, outputSpectrumBuffer, fftSize * MemoryLayout<Double>.size)
                memcpy(outputSpectrumBuffer, tempBuffer + halfSize, halfSize * MemoryLayout<Double>.size)
                memcpy(outputSpectrumBuffer + halfSize, tempBuffer, halfSize * MemoryLayout<Double>.size)
                
                memcpy(tempBuffer, outputFrequencyBuffer, fftSize * MemoryLayout<Double>.size)
                memcpy(outputFrequencyBuffer, tempBuffer + halfSize, halfSize * MemoryLayout<Double>.size)
                memcpy(outputFrequencyBuffer + halfSize, tempBuffer, halfSize * MemoryLayout<Double>.size)
        }
}


//vDSP_fft_ziptD
//Computes a forward or inverse in-place, double-precision complex FFT using a temporary buffer.
//extern void vDSP_fft_ziptD(FFTSetupD __Setup, const DSPDoubleSplitComplex * __C, vDSP_Stride __IC, const DSPDoubleSplitComplex * __Buffer, vDSP_Length __Log2N, FFTDirection __Direction);
//Parameters
//__Setup
//The FFT setup structure for this transform. The setup’s structure Log2N must be greater than or equal to this function’s Log2N.
//                                
//                                __C
//                                A pointer to the input-output data.
//                                
//                                __IC
//                                The stride between the elements in C, set to 1 for best performance.
//                                
//                                __Buffer
//                                A temporary vector that the operation uses for storing interim results. The real and imaginary parts of the buffer must both contain the lesser of 2Log2N elements or 16,384 bytes. For best performance, the buffer addresses must be 16-byte aligned or better.
//                                
//                                __Log2N
//                                The base 2 exponent of the number of elements to process. For example, to process 1024 elements, specify 10 for parameter Log2N.
//                                
//                                __Direction
//                                A flag that specifies the transform direction. Pass kFFTDirection_Forward to transform from the time domain to the frequency domain. Pass kFFTDirection_Inverse to transform from the frequency domain to the time domain.
