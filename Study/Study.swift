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
        let processingTime: TimeInterval
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
                let startTime = CFAbsoluteTimeGetCurrent()
                
                // The magnitudes from StudyData are already in dB
                let magnitudesDB = data.magnitudeSpectrum
                let halfSize = magnitudesDB.count
                
                print("Study: Starting analysis with \(halfSize) bins")
                
                // Generate frequency array for the full spectrum
                let freqGenStartTime = CFAbsoluteTimeGetCurrent()
                let fullFrequencies = generateFrequencyArray(
                        count: halfSize,
                        sampleRate: data.sampleRate
                )
                print("Study: Frequency array generation took \((CFAbsoluteTimeGetCurrent() - freqGenStartTime) * 1000)ms")
                
                // Create bin mapper
                let binMapperStartTime = CFAbsoluteTimeGetCurrent()
                let binMapper = BinMapper(config: config, halfSize: halfSize)
                let binFrequencies = binMapper.binFrequencies
                print("Study: BinMapper initialization took \((CFAbsoluteTimeGetCurrent() - binMapperStartTime) * 1000)ms")
                
                // Map the original spectrum to display bins
                let mapOriginalStartTime = CFAbsoluteTimeGetCurrent()
                let mappedOriginal = binMapper.mapSpectrum(magnitudesDB)
                print("Study: Original spectrum mapping took \((CFAbsoluteTimeGetCurrent() - mapOriginalStartTime) * 1000)ms")
                
                // Fit noise floor on the full resolution data
                let noiseFloorStartTime = CFAbsoluteTimeGetCurrent()
                let noiseFloorFull = fitNoiseFloor(
                        magnitudesDB: magnitudesDB,
                        frequencies: fullFrequencies,
                        config: config.noiseFloor
                )
                let noiseFloorTime = (CFAbsoluteTimeGetCurrent() - noiseFloorStartTime) * 1000
                print("Study: Noise floor fitting (\(config.noiseFloor.method)) took \(noiseFloorTime)ms")
                
                // Map noise floor to display bins
                let mapNoiseFloorStartTime = CFAbsoluteTimeGetCurrent()
                let mappedNoiseFloor = binMapper.mapSpectrum(noiseFloorFull)
                print("Study: Noise floor mapping took \((CFAbsoluteTimeGetCurrent() - mapNoiseFloorStartTime) * 1000)ms")
                
                // Denoise spectrum at full resolution
                let denoiseStartTime = CFAbsoluteTimeGetCurrent()
                let denoisedFull = denoiseSpectrum(
                        magnitudesDB: magnitudesDB,
                        noiseFloorDB: noiseFloorFull
                )
                print("Study: Denoising took \((CFAbsoluteTimeGetCurrent() - denoiseStartTime) * 1000)ms")
                
                // Map denoised spectrum to display bins
                let mapDenoisedStartTime = CFAbsoluteTimeGetCurrent()
                let mappedDenoised = binMapper.mapSpectrum(denoisedFull)
                print("Study: Denoised spectrum mapping took \((CFAbsoluteTimeGetCurrent() - mapDenoisedStartTime) * 1000)ms")
                
                // Find peaks in the denoised spectrum
                let peaksStartTime = CFAbsoluteTimeGetCurrent()
                let peaks = findPeaks(
                        in: mappedDenoised,
                        frequencies: binFrequencies,
                        config: config.peakDetection
                )
                let peaksTime = (CFAbsoluteTimeGetCurrent() - peaksStartTime) * 1000
                print("Study: Peak detection found \(peaks.count) peaks in \(peaksTime)ms")
                
                // Print peak details
                for (i, peak) in peaks.prefix(5).enumerated() {
                        print("  Peak \(i+1): \(String(format: "%.1f", peak.frequency)) Hz, \(String(format: "%.1f", peak.magnitude)) dB, prominence: \(String(format: "%.1f", peak.prominence)) dB")
                }
                
                let totalTime = CFAbsoluteTimeGetCurrent() - startTime
                print("Study: Total processing time: \(String(format: "%.2f", totalTime * 1000))ms")
                print("Study: Summary - Original: \(mappedOriginal.count) bins, Peaks: \(peaks.count), Range: [\(String(format: "%.1f", mappedOriginal.min() ?? 0)), \(String(format: "%.1f", mappedOriginal.max() ?? 0))] dB")
                
                return StudyResult(
                        originalSpectrum: mappedOriginal,
                        noiseFloor: mappedNoiseFloor,
                        denoisedSpectrum: mappedDenoised,
                        frequencies: binFrequencies,
                        peaks: peaks,
                        timestamp: Date(timeIntervalSince1970: data.timestamp),
                        hpsSpectrum: nil,
                        processingTime: totalTime
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
        
        static func denoiseSpectrum(magnitudesDB: [Float], noiseFloorDB: [Float]) -> [Float] {
                let count = magnitudesDB.count
                var denoised = [Float](repeating: -80, count: count)
                
                for i in 0..<count {
                        // If signal is above noise floor, keep original value
                        if magnitudesDB[i] > noiseFloorDB[i] {
                                denoised[i] = magnitudesDB[i]
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
