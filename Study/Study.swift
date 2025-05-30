import Foundation
import Accelerate
import CoreML

// MARK: - Result Types

struct StudyResult {
        let originalSpectrum: [Float]
        let noiseFloor: [Float]
        let denoisedSpectrum: [Float]
        let frequencies: [Float]
        let peaks: [Peak]
        let timestamp: Date
        let hpsSpectrum: [Float]?
}


struct Peak {
        let index: Int
        let frequency: Float
        let magnitude: Float
        let prominence: Float
        let leftBase: Int
        let rightBase: Int
}

// MARK: - Study Analysis Functions

enum Study {
        
        // MARK: - Main Entry Point
        
        /// Perform comprehensive spectral analysis
        /// This is now a pure function - no async, no dispatch queues
        static func perform(data: SpectrumAnalyzer.StudyData, config: AnalyzerConfig) -> StudyResult {
                
                // Compute magnitudes from FFT data
                let magnitudes = computeMagnitudes(real: data.fftReal, imag: data.fftImag)
                
                // Generate frequency array
                let frequencies = generateFrequencyArray(
                        count: magnitudes.count,
                        sampleRate: data.sampleRate
                )
                
                // Fit noise floor using configured method
                let noiseFloor = fitNoiseFloor(
                        magnitudes: magnitudes,
                        frequencies: frequencies,
                        config: config.noiseFloor
                )
                
                // Denoise spectrum
                let denoised = denoiseSpectrum(
                        magnitudes: magnitudes,
                        noiseFloor: noiseFloor
                )
                
                // Find peaks
                let peaks = findPeaks(
                        in: denoised,
                        frequencies: frequencies,
                        config: config.peakDetection
                )
                
                let hps = computeWeightedHPS(
                        magnitudes: magnitudes,
                        frequencies: frequencies
                )
                
                return StudyResult(
                        originalSpectrum: magnitudes,
                        noiseFloor: noiseFloor,
                        denoisedSpectrum: denoised,
                        frequencies: frequencies,
                        peaks: peaks,
                        timestamp: Date(timeIntervalSince1970: data.timestamp),
                        hpsSpectrum: hps,
                )
        }
        
                
        static func computeWeightedHPS(magnitudes: [Float], frequencies: [Float]) -> [Float] {
                // Mock implementation - replace with real HPS later
                let count = magnitudes.count
                var hps = [Float](repeating: 0, count: count)
                
                // For now, just create a mock spectrum with peaks at harmonics
                for i in 0..<count {
                        let freq = frequencies[i]
                        // Create mock peaks at 440Hz and harmonics
                        let fundamental: Float = 440.0
                        for harmonic in 1...5 {
                                let harmonicFreq = fundamental * Float(harmonic)
                                let distance = abs(freq - harmonicFreq)
                                if distance < 20 {
                                        let weight = 1.0 / Float(harmonic)
                                        hps[i] += magnitudes[i] * weight * exp(-distance / 10)
                                }
                        }
                }
                
                return hps
        }

        
//        // MARK: - Compute Spectral Centroid
//        
//        static func computeSpectralCentroid(magnitudes: [Float],
//                                            frequencies: [Float]) -> Float {
//                var weightedSum: Float = 0
//                var magnitudeSum: Float = 0
//                
//                for (mag, freq) in zip(magnitudes, frequencies) {
//                        weightedSum += freq * mag
//                        magnitudeSum += mag
//                }
//                
//                return magnitudeSum > 0 ? weightedSum / magnitudeSum : 0
//        }

        
        // MARK: - Denoising
        
        static func denoiseSpectrum(magnitudes: [Float], noiseFloor: [Float]) -> [Float] {
                let count = magnitudes.count
                var denoised = [Float](repeating: -80, count: count)
                
                for i in 0..<count {
                        // If signal is above noise floor, keep original value
                        // Otherwise, set to minimum
                        if magnitudes[i] > noiseFloor[i] {
                                denoised[i] = magnitudes[i]
                        } else {
                                denoised[i] = -80
                        }
                }
                
                return denoised
        }
        
        // MARK: Moving Minimum
        
        static func movingMinimum(_ data: [Float], windowSize: Int) -> [Float] {
                let count = data.count
                var result = [Float](repeating: 0, count: count)
                
                for i in 0..<count {
                        let start = max(0, i - windowSize/2)
                        let end = min(count, i + windowSize/2 + 1)
                        result[i] = data[start..<end].min() ?? data[i]
                }
                
                return result
        }
        // MARK: Gaussian Smooth
        static func gaussianSmooth(_ data: [Float], sigma: Float) -> [Float] {
                let kernelSize = Int(ceil(sigma * 3)) * 2 + 1
                let kernel = gaussianKernel(size: kernelSize, sigma: sigma)
                
                var result = [Float](repeating: 0, count: data.count)
                let halfKernel = kernelSize / 2
                
                for i in 0..<data.count {
                        var sum: Float = 0
                        var weightSum: Float = 0
                        
                        for j in 0..<kernelSize {
                                let dataIndex = i + j - halfKernel
                                if dataIndex >= 0 && dataIndex < data.count {
                                        sum += data[dataIndex] * kernel[j]
                                        weightSum += kernel[j]
                                }
                        }
                        
                        result[i] = sum / weightSum
                }
                
                return result
        }
        // MARK: (Gaussian Kernel)
        private static func gaussianKernel(size: Int, sigma: Float) -> [Float] {
                let center = Float(size / 2)
                let twoSigmaSquared = 2 * sigma * sigma
                
                var kernel = [Float](repeating: 0, count: size)
                var sum: Float = 0
                
                for i in 0..<size {
                        let x = Float(i) - center
                        kernel[i] = exp(-(x * x) / twoSigmaSquared)
                        sum += kernel[i]
                }
                
                // Normalize
                for i in 0..<size {
                        kernel[i] /= sum
                }
                
                return kernel
        }
        
        // MARK: - Compute Magnitudes
        
        static func computeMagnitudes(real: [Float], imag: [Float]) -> [Float] {
                return zip(real, imag).map { sqrt($0 * $0 + $1 * $1) }
        }
        // MARK: - Generate Frequency Array
        static func generateFrequencyArray(count: Int, sampleRate: Float) -> [Float] {
                let binWidth = sampleRate / Float(count * 2)  // count is half FFT size
                return (0..<count).map { Float($0) * binWidth }
        }
}


enum SmoothingFunctions {
        @inline(__always)
        static func exponentialSmooth(_ current: UnsafeMutablePointer<Float>,
                                      _ target: UnsafePointer<Float>,
                                      _ count: Int,
                                      _ alpha: Float) {
                let beta = 1.0 - alpha
                for i in 0..<count {
                        current[i] = current[i] * alpha + target[i] * beta
                }
        }
}
