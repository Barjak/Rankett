import SwiftUI
import AVFoundation
import Accelerate
import Foundation

class FFTStage: ProcessingStage {
    typealias Input = [[Float]]  // Windowed samples from WindowingStage
    typealias Output = [SpectralData]  // Spectral data for each window
    
    private let fftSetup: vDSP.FFT<DSPSplitComplex>
    private let fftSize: Int
    private let sampleRate: Double
    private let halfSize: Int
    
    init(fftSize: Int, sampleRate: Double) {
        self.fftSize = fftSize
        self.sampleRate = sampleRate
        self.halfSize = fftSize / 2
        
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("Failed to create FFT setup")
        }
        self.fftSetup = setup
    }
    
    func process(_ input: [[Float]]) -> [SpectralData] {
        return input.map { windowedSamples in
            processWindow(windowedSamples)
        }
    }
    
    private func processWindow(_ samples: [Float]) -> SpectralData {
        // Prepare split complex format for real FFT
        var realPart = [Float](repeating: 0, count: halfSize)
        var imagPart = [Float](repeating: 0, count: halfSize)
        
        // Pack real input for FFT (even/odd split)
        for i in 0..<halfSize {
            realPart[i] = samples[i * 2]
            imagPart[i] = samples[i * 2 + 1]
        }
        
        // Perform FFT and calculate magnitudes
        let magnitudes = realPart.withUnsafeMutableBufferPointer { realPtr in
            imagPart.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                
                // Perform FFT
                fftSetup.forward(input: splitComplex, output: &splitComplex)
                
                // Calculate magnitudes
                var mags = [Float](repeating: 0, count: halfSize)
                vDSP_zvmags(&splitComplex, 1, &mags, 1, vDSP_Length(halfSize))
                
                return mags
            }
        }
        
        // Generate frequency array
        let frequencies = (0..<halfSize).map { i in
            Float(Double(i) * sampleRate / Double(fftSize))
        }
        
        return SpectralData(
            magnitudes: magnitudes,
            frequencies: frequencies,
            sampleRate: sampleRate
        )
    }
}
