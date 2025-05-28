//
//  SpectrumAnalyzerConfig.swift
//  ShitPipes
//
//  Created by Ralph Richards on 5/27/25.
//
import SwiftUI
import AVFoundation
import Accelerate
import Foundation

// MARK: - Configuration
struct SpectrumAnalyzerConfig {
    // FFT Parameters
    let fftSize: Int = 4096 * 2
    let sampleRate: Double = 44100
    
    // Display Parameters
    let outputBinCount: Int = 512  // Number of bins to display (only used when useFrequencyBinning is true)
    let useLogFrequencyScale: Bool = true
    let useFrequencyBinning: Bool = true  // NEW: Control whether to bin the data
    let minFrequency: Double = 20.0  // Hz
    let maxFrequency: Double = 20000.0  // Hz
    
    // Processing Parameters
    let overlapRatio: Double = 0.700  // 0.0 to 1.0 (0.75 = 75% overlap)
    let smoothingFactor: Float = 0.80  // 0.0 to 1.0 (higher = more smoothing)
    
    // Performance Parameters
    let updateRateHz: Double = 60.0  // Display update rate
    let processOnBackgroundQueue: Bool = true
    
    // Computed properties
    var hopSize: Int {
        Int(Double(fftSize) * (1.0 - overlapRatio))
    }
    
    var frequencyResolution: Double {
        sampleRate / Double(fftSize)
    }
    
    var nyquistFrequency: Double {
        sampleRate / 2.0
    }
}
