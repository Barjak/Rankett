import Foundation
import Accelerate
import CoreML

// MARK: - Result Types
struct StudyResult {
        let originalSpectrum: [Float]  // Full resolution magnitude spectrum
        let noiseFloor: [Float]
        let denoisedSpectrum: [Float]
        let frequencies: [Float]
        let peaks: [Peak]
        let timestamp: Date
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
        static func perform(audioWindow: [Float], config: AnalyzerConfig) -> StudyResult {
                let startTime = CFAbsoluteTimeGetCurrent()
                
                // Perform FFT directly here
                let fftSize = config.fft.size
                let halfSize = fftSize / 2
                
                // Create FFT setup
                let log2n = vDSP_Length(log2(Float(fftSize)))
                guard let fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
                        fatalError("Failed to create FFT setup")
                }
                
                // Allocate FFT buffers
                let realPtr = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                let imagPtr = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                defer {
                        realPtr.deallocate()
                        imagPtr.deallocate()
                }
                
                // Pack real input
                for i in 0..<halfSize {
                        realPtr[i] = audioWindow[i * 2]
                        imagPtr[i] = audioWindow[i * 2 + 1]
                }
                
                // Perform FFT
                var splitComplex = DSPSplitComplex(realp: realPtr, imagp: imagPtr)
                fftSetup.forward(input: splitComplex, output: &splitComplex)
                
                // Compute magnitude spectrum
                let magnitudePtr = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                defer { magnitudePtr.deallocate() }
                
                // Calculate magnitudes
                vDSP_zvmags(&splitComplex, 1, magnitudePtr, 1, vDSP_Length(halfSize))
                
                // Convert to dB
                var floor: Float = 1e-10
                var ceiling: Float = Float.greatestFiniteMagnitude
                vDSP_vclip(magnitudePtr, 1, &floor, &ceiling, magnitudePtr, 1, vDSP_Length(halfSize))
                
                var reference: Float = 1.0
                vDSP_vdbcon(magnitudePtr, 1, &reference, magnitudePtr, 1, vDSP_Length(halfSize), 1)
                
                // Create magnitude array
                let magnitudesDB = Array(UnsafeBufferPointer(start: magnitudePtr, count: halfSize))
                
                print("Study: Starting analysis with \(halfSize) bins")
                
                // Generate frequency array
                let frequencies = generateFrequencyArray(count: halfSize, sampleRate: Float(config.audio.sampleRate))
                
                // Fit noise floor
                let noiseFloor = fitNoiseFloor(
                        magnitudesDB: magnitudesDB,
                        frequencies: frequencies,
                        config: config.noiseFloor
                )
                
                // Denoise spectrum
                let denoised = denoiseSpectrum(
                        magnitudesDB: magnitudesDB,
                        noiseFloorDB: noiseFloor
                )
                
                // Find peaks in full resolution
                let peaks = findPeaks(
                        in: denoised,
                        frequencies: frequencies,
                        config: config.peakDetection
                )
                
                let totalTime = CFAbsoluteTimeGetCurrent() - startTime
                print("Study: Total processing time: \(String(format: "%.2f", totalTime * 1000))ms")
                
                return StudyResult(
                        originalSpectrum: magnitudesDB,
                        noiseFloor: noiseFloor,
                        denoisedSpectrum: denoised,
                        frequencies: frequencies,
                        peaks: peaks,
                        timestamp: Date(),
                        processingTime: totalTime
                )
        }
        
        // MARK: - Generate Frequency Array
        static func generateFrequencyArray(count: Int, sampleRate: Float) -> [Float] {
                let binWidth = sampleRate / Float(count * 2)
                return (0..<count).map { Float($0) * binWidth }
        }
}
