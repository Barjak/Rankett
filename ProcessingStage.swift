//
//  ProcessingStage.swift
//  ShitPipes
//
//  Created by Ralph Richards on 5/27/25.
//
import SwiftUI
import AVFoundation
import Accelerate
import Foundation

/// A protocol representing a single stage in a signal processing pipeline.
protocol ProcessingStage {
    /// Processes the input signal and returns the transformed signal.
    func process(_ input: [Float]) -> [Float]
}

/// A pipeline that processes signals through a chain of ProcessingStages.
class SignalPipeline {
    private var stages: [ProcessingStage] = []

    /// Adds a new processing stage to the pipeline.
    func addStage(_ stage: ProcessingStage) {
        stages.append(stage)
    }

    /// Processes an input signal through all added stages in order.
    func run(input: [Float]) -> [Float] {
        return stages.reduce(input) { signal, stage in
            stage.process(signal)
        }
    }

    /// Clears all stages from the pipeline.
    func reset() {
        stages.removeAll()
    }
}
