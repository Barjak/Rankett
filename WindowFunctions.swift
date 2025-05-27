//
//  WindowFunctions.swift
//  ShitPipes
//
//  Created by Ralph Richards on 5/27/25.
//

// MARK: - Window Functions
import SwiftUI
import AVFoundation
import Accelerate
import Foundation
enum WindowType {
    case blackmanHarris
    case hann
    case hamming
    
    func createWindow(size: Int) -> [Float] {
        switch self {
        case .blackmanHarris:
            return createBlackmanHarrisWindow(size: size)
        case .hann:
            return vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        case .hamming:
            return vDSP.window(ofType: Float.self, usingSequence: .hamming, count: size, isHalfWindow: false)
        }
    }
}

func createBlackmanHarrisWindow(size: Int) -> [Float] {
    let coefficients: [Float] = [0.35875, 0.48829, 0.14128, 0.01168]
    var window = [Float](repeating: 0, count: size)
    
    for i in 0..<size {
        let x = 2.0 * Float.pi * Float(i) / Float(size - 1)
        window[i] = coefficients[0]
                  - coefficients[1] * cos(x)
                  + coefficients[2] * cos(2 * x)
                  - coefficients[3] * cos(3 * x)
    }
    
    return window
}


