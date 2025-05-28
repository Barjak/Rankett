// Pipeline/Stages/Transform/WindowingStage.swift
import Foundation
import Accelerate

class WindowingStage: ProcessingStage {
    typealias Input = [[Float]]  // Multiple windows from CircularBufferStage
    typealias Output = [[Float]] // Windowed samples
    
    private let window: [Float]
    private let windowType: WindowType
    
    init(windowType: WindowType, size: Int) {
        self.windowType = windowType
        self.window = windowType.createWindow(size: size)
    }
    
    func process(_ input: [[Float]]) -> [[Float]] {
        return input.map { samples in
            // Apply window to each set of samples
            var windowedSamples = [Float](repeating: 0, count: samples.count)
            
            // Use vDSP for efficient element-wise multiplication
            vDSP_vmul(samples, 1, window, 1, &windowedSamples, 1, vDSP_Length(samples.count))
            
            return windowedSamples
        }
    }
}
