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
                        in: denoisedFull,
                        frequencies: fullFrequencies,
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
        
// TODO: Implement this. Magnitude of each overtone is 1/
//        static func computeWeightedHPS(magnitudes: [Float], frequencies: [Float]) -> [Float] {
//
//        }


        
        // MARK: - Generate Frequency Array
        static func generateFrequencyArray(count: Int, sampleRate: Float) -> [Float] {
                let binWidth = sampleRate / Float(count * 2)  // count is half FFT size
                return (0..<count).map { Float($0) * binWidth }
        }
}
