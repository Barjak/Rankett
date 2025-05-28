// Pipeline/Core/ProcessingStage.swift
import Foundation

protocol ProcessingStage {
    associatedtype Input
    associatedtype Output
    
    func process(_ input: Input) -> Output
}

// For audio-specific stages
protocol AudioProcessingStage: ProcessingStage where Input == AudioBuffer, Output == AudioBuffer {}

// Data structures
struct AudioBuffer {
    let samples: [Float]
    let sampleRate: Double
    let frameCount: Int
}

struct SpectralData {
    let magnitudes: [Float]
    let frequencies: [Float]
    let sampleRate: Double
}
