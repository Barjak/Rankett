import Foundation
import Accelerate
import QuartzCore

// MARK: (Pack Real Input)
enum FFTFunctions {
        @inline(__always)
        static func packRealInput(_ input: UnsafePointer<Float>,
                                  _ real: UnsafeMutablePointer<Float>,
                                  _ imag: UnsafeMutablePointer<Float>,
                                  _ halfSize: Int) {
                for i in 0..<halfSize {
                        real[i] = input[i * 2]
                        imag[i] = input[i * 2 + 1]
                }
        }
}
// MARK: Compute Magnitudes DB
enum MagnitudeFunctions {
        @inline(__always)
        static func computeMagnitudesDB(_ real: UnsafePointer<Float>,
                                        _ imag: UnsafePointer<Float>,
                                        _ output: UnsafeMutablePointer<Float>,
                                        _ count: Int) {
                var splitComplex = DSPSplitComplex(
                        realp: UnsafeMutablePointer(mutating: real),
                        imagp: UnsafeMutablePointer(mutating: imag)
                )
                
                // Calculate magnitudes
                vDSP_zvmags(&splitComplex, 1, output, 1, vDSP_Length(count))
                
                // Clamp to avoid log(0)
                var floor: Float = 1e-10
                var ceiling: Float = Float.greatestFiniteMagnitude
                vDSP_vclip(output, 1, &floor, &ceiling, output, 1, vDSP_Length(count))
                
                // Convert to dB
                var reference: Float = 1.0
                vDSP_vdbcon(output, 1, &reference, output, 1, vDSP_Length(count), 1)
        }
}

// MARK: - Spectrum Analyzer

final class SpectrumAnalyzer {
        // Configuration
        private let config: AnalyzerConfig
        
        // Derived values
        private let halfSize: Int
        
        // FFT Setup
        private let fftSetup: vDSP.FFT<DSPSplitComplex>
        
        // Pre-computed data
        private let window: ContiguousArray<Float>
        private let binMap: [Int]  // For log frequency mapping
        
        // All working buffers
        private let windowedBuffer: UnsafeMutableBufferPointer<Float>
        private let fftReal: UnsafeMutableBufferPointer<Float>
        private let fftImag: UnsafeMutableBufferPointer<Float>
        private let magnitude: UnsafeMutableBufferPointer<Float>
        private let mappedBins: UnsafeMutableBufferPointer<Float>
        private let smoothedOutput: UnsafeMutableBufferPointer<Float>
        
        // Thread safety for data export
        private let dataLock = NSLock()
        
        init(config: AnalyzerConfig = .default) {
                self.config = config
                self.halfSize = config.fft.size / 2
                
                // Create FFT setup
                let log2n = vDSP_Length(log2(Float(config.fft.size)))
                guard let setup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
                        fatalError("Failed to create FFT setup")
                }
                self.fftSetup = setup
                
                // Pre-compute window
                self.window = WindowFunctions.createBlackmanHarris(size: config.fft.size)
                
                // Pre-compute bin mapping for log frequency
                if config.rendering.useLogFrequencyScale {
                        let nyquist = config.audio.nyquistFrequency
                        let freqResolution = config.fft.frequencyResolution
                        let logMin = log10(config.rendering.minFrequency)
                        let logMax = log10(min(config.rendering.maxFrequency, nyquist))
                        let halfSize = self.halfSize
                        self.binMap = (0..<config.fft.outputBinCount).map { i in
                                let logFreq = logMin + (logMax - logMin) * Double(i) / Double(config.fft.outputBinCount - 1)
                                let freq = pow(10, logFreq)
                                let binIndex = Int(freq / freqResolution)
                                return min(binIndex, halfSize - 1)
                        }
                } else {
                        self.binMap = Array(0..<min(config.fft.outputBinCount, halfSize))
                }
                
                // Allocate all working buffers
                let windowedPtr = UnsafeMutablePointer<Float>.allocate(capacity: config.fft.size)
                let realPtr = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                let imagPtr = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                let magPtr = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                let mappedPtr = UnsafeMutablePointer<Float>.allocate(capacity: config.fft.outputBinCount)
                let smoothPtr = UnsafeMutablePointer<Float>.allocate(capacity: config.fft.outputBinCount)
                
                self.windowedBuffer = UnsafeMutableBufferPointer(start: windowedPtr, count: config.fft.size)
                self.fftReal = UnsafeMutableBufferPointer(start: realPtr, count: halfSize)
                self.fftImag = UnsafeMutableBufferPointer(start: imagPtr, count: halfSize)
                self.magnitude = UnsafeMutableBufferPointer(start: magPtr, count: halfSize)
                self.mappedBins = UnsafeMutableBufferPointer(start: mappedPtr, count: config.fft.outputBinCount)
                self.smoothedOutput = UnsafeMutableBufferPointer(start: smoothPtr, count: config.fft.outputBinCount)
                
                // Initialize buffers
                windowedBuffer.initialize(repeating: 0)
                fftReal.initialize(repeating: 0)
                fftImag.initialize(repeating: 0)
                magnitude.initialize(repeating: -80.0)  // Start at minimum dB
                mappedBins.initialize(repeating: -80.0)
                smoothedOutput.initialize(repeating: -80.0)
        }
        
        deinit {
                windowedBuffer.deallocate()
                fftReal.deallocate()
                fftImag.deallocate()
                magnitude.deallocate()
                mappedBins.deallocate()
                smoothedOutput.deallocate()
        }
        
        @inline(__always)
        func processWithoutSmoothing(_ input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>) {
                // Get base pointers
                let windowedPtr = windowedBuffer.baseAddress!
                let realPtr = fftReal.baseAddress!
                let imagPtr = fftImag.baseAddress!
                let magPtr = magnitude.baseAddress!
                
                // Step 1: Copy input and apply window
                memcpy(windowedPtr, input, config.fft.size * MemoryLayout<Float>.size)
                window.withUnsafeBufferPointer { windowPtr in
                        WindowFunctions.applyBlackmanHarris(windowedPtr, windowPtr.baseAddress!, config.fft.size)
                }
                
//                 Step 2: Pack for FFT
                FFTFunctions.packRealInput(windowedPtr, realPtr, imagPtr, halfSize)
//                FFTFunctions.packRealInput(input, realPtr, imagPtr, halfSize)
                // WHY? If you comment out the windowing and just pass the input instead of windowedPtr, then the jumping goes away.

                // Step 3: Perform FFT
                var splitComplex = DSPSplitComplex(realp: realPtr, imagp: imagPtr)
                fftSetup.forward(input: splitComplex, output: &splitComplex)
                
                // Step 4: Compute magnitudes in dB
                MagnitudeFunctions.computeMagnitudesDB(realPtr, imagPtr, magPtr, halfSize)
                
                // Step 5: Map to output bins (linear or log) - NO SMOOTHING
                let freqRes = Float(config.fft.frequencyResolution)
                let minLog  = log10(config.rendering.minFrequency)
                let maxLog  = log10(min(config.rendering.maxFrequency,
                                        config.audio.nyquistFrequency))
                let Nout    = config.fft.outputBinCount
                let α       = config.rendering.smoothingFactor
                
                for i in 0..<Nout {
                        // a) compute fractional bin index
                        let binF: Float
                        if config.rendering.useLogFrequencyScale {
                                let t = Float(i) / Float(Nout - 1)
                                let logf = minLog + (maxLog - minLog) * Double(t)
                                let f    = Float(pow(10, logf))
                                binF = f / freqRes
                        } else {
                                binF = Float(i) * Float(halfSize - 1) / Float(Nout - 1)
                        }
                        
                        // b) linear interpolate between floor(binF) and ceil(binF)
                        let lo   = Int(floor(binF))
                        let hi   = min(lo + 1, halfSize - 1)
                        let frac = binF - Float(lo)
                        let magL = magPtr[lo]
                        let magH = magPtr[hi]
                        let interp = (1 - frac) * magL + frac * magH
                        
                        // c) exponential smoothing
                        let prev = output[i]
                        let sm   = α * interp + (1 - α) * prev
                        output[i] = sm
                        
                        // output
                        output[i] = sm
                }
        }
        
        // MARK: - Data Export for Study
        
        struct StudyData {
                let fftReal: [Float]
                let fftImag: [Float]
                let timeDomain: [Float]
                let magnitudeSpectrum: [Float]
                let sampleRate: Float
                let timestamp: TimeInterval
        }
        
        /// Safely capture current analysis data for external study processing
        func captureStudyData() -> StudyData {
                dataLock.lock()
                defer { dataLock.unlock() }
                
                // Create copies of the current data
                let realCopy = Array(fftReal)
                let imagCopy = Array(fftImag)
                let timeCopy = Array(windowedBuffer)  // This has the windowed data
                let magCopy = Array(magnitude)
                
                return StudyData(
                        fftReal: realCopy,
                        fftImag: imagCopy,
                        timeDomain: timeCopy,
                        magnitudeSpectrum: magCopy,
                        sampleRate: Float(config.audio.sampleRate),
                        timestamp: CACurrentMediaTime()
                )
        }
        
        /// Get current configuration
        var configuration: AnalyzerConfig {
                return config
        }
        
        /// Get computed values for external use
        var computedValues: (fftSize: Int, halfSize: Int, outputBinCount: Int, binMapping: [Int]) {
                return (config.fft.size, halfSize, config.fft.outputBinCount, binMap)
        }
}
