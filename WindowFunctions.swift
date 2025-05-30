import Foundation
import Accelerate


enum WindowFunctions {
        @inline(__always)
        static func applyBlackmanHarris(_ input: UnsafeMutablePointer<Float>,
                                        _ window: UnsafePointer<Float>,
                                        _ count: Int) {
                vDSP_vmul(input, 1, window, 1, input, 1, vDSP_Length(count))
        }
        
        static func createBlackmanHarris(size: Int) -> ContiguousArray<Float> {
                var window = ContiguousArray<Float>(repeating: 0, count: size)
                let a0: Float = 0.35875
                let a1: Float = 0.48829
                let a2: Float = 0.14128
                let a3: Float = 0.01168
                
                for i in 0..<size {
                        let phase = 2.0 * Float.pi * Float(i) / Float(size - 1)
                        window[i] = a0 - a1 * cos(phase) + a2 * cos(2 * phase) - a3 * cos(3 * phase)
                }
                return window
        }
}
enum WindowType {
        case none
        case hann
        case hamming
        case blackmanHarris
        
        func createWindow(size: Int) -> [Float] {
                switch self {
                case .none:
                        return Array(repeating: 1.0, count: size)
                case .hann:
                        return vDSP.window(ofType: Float.self,
                                           usingSequence: .hanningDenormalized,
                                           count: size,
                                           isHalfWindow: false)
                case .hamming:
                        return vDSP.window(ofType: Float.self,
                                           usingSequence: .hamming,
                                           count: size,
                                           isHalfWindow: false)
                case .blackmanHarris:
                        return createBlackmanHarrisWindow(size: size)
                }
        }
}

private func createBlackmanHarrisWindow(size: Int) -> [Float] {
        let a0: Float = 0.35875
        let a1: Float = 0.48829
        let a2: Float = 0.14128
        let a3: Float = 0.01168
        
        return (0..<size).map { i in
                let phase = 2.0 * Float.pi * Float(i) / Float(size - 1)
                return a0 - a1 * cos(phase) + a2 * cos(2 * phase) - a3 * cos(3 * phase)
        }
}
