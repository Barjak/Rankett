//
//  SpectrumView.swift
//  ShitPipes
//
//  Created by Ralph Richards on 5/27/25.
//
import SwiftUI
import AVFoundation
import Accelerate
import Foundation

// MARK: - Spectrum View
struct SpectrumView: UIViewRepresentable {
    let spectrumData: [Float]
    let frequencyData: [Float]  // NEW
    let config: SpectrumAnalyzerConfig
    
    func makeUIView(context: Context) -> SpectrumGraphView {
        let view = SpectrumGraphView()
        view.config = config
        view.isOpaque = true
        view.backgroundColor = .black
        return view
    }
    
    func updateUIView(_ uiView: SpectrumGraphView, context: Context) {
        uiView.spectrumData = spectrumData
        uiView.frequencyData = frequencyData  // NEW
        uiView.setNeedsDisplay()
    }
}

class SpectrumGraphView: UIView {
    var spectrumData: [Float] = []
    var frequencyData: [Float] = []  // NEW: Add frequency data
    var config = SpectrumAnalyzerConfig()
    
    override func draw(_ rect: CGRect) {
        guard spectrumData.count > 1 else { return }
        
        guard let context = UIGraphicsGetCurrentContext() else { return }
        
        // Styling
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        
        let padding: CGFloat = 20
        let drawableWidth = rect.width - (2 * padding)
        let drawableHeight = rect.height - (2 * padding)
        
        // Dynamic range for dB scale
        let minDB: Float = -160
        let maxDB: Float = 100
        let dbRange = maxDB - minDB
        
        // Draw frequency grid lines
        drawFrequencyGrid(context: context, rect: rect, padding: padding)
        
        // Draw spectrum
        context.beginPath()
        
        if config.useFrequencyBinning || !config.useLogFrequencyScale {
            // Original linear rendering for binned data
            for i in 0..<spectrumData.count {
                let x = padding + (CGFloat(i) * drawableWidth / CGFloat(spectrumData.count - 1))
                
                // Clamp and normalize dB value
                let dbValue = max(minDB, min(maxDB, spectrumData[i]))
                let normalizedValue = (dbValue - minDB) / dbRange
                let y = padding + drawableHeight * (1 - CGFloat(normalizedValue))
                
                if i == 0 {
                    context.move(to: CGPoint(x: x, y: y))
                } else {
                    context.addLine(to: CGPoint(x: x, y: y))
                }
            }
        } else {
            // Logarithmic rendering for unbinned data
            let logMin = log10(config.minFrequency)
            let logMax = log10(min(config.maxFrequency, config.nyquistFrequency))
            
            var firstPoint = true
            
            for i in 0..<spectrumData.count {
                let frequency = Double(i) * config.frequencyResolution
                
                // Skip frequencies outside our range
                if frequency < config.minFrequency || frequency > config.maxFrequency {
                    continue
                }
                
                // Calculate logarithmic x position
                let logFreq = log10(frequency)
                let normalizedX = (logFreq - logMin) / (logMax - logMin)
                let x = padding + CGFloat(normalizedX) * drawableWidth
                
                // Calculate y position
                let dbValue = max(minDB, min(maxDB, spectrumData[i]))
                let normalizedValue = (dbValue - minDB) / dbRange
                let y = padding + drawableHeight * (1 - CGFloat(normalizedValue))
                
                if firstPoint {
                    context.move(to: CGPoint(x: x, y: y))
                    firstPoint = false
                } else {
                    context.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        
        context.strokePath()
    }
    
    private func drawFrequencyGrid(context: CGContext, rect: CGRect, padding: CGFloat) {
        context.saveGState()
        context.setStrokeColor(UIColor.systemGray.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(1)
        
        // Draw horizontal dB grid lines
        let dbLines: [Float] = [0, -20, -40, -60]
        for db in dbLines {
            let normalizedValue = (db - (-80)) / 80.0
            let y = padding + (rect.height - 2 * padding) * (1 - CGFloat(normalizedValue))
            
            context.move(to: CGPoint(x: padding, y: y))
            context.addLine(to: CGPoint(x: rect.width - padding, y: y))
        }
        
        context.strokePath()
        context.restoreGState()
    }
}
