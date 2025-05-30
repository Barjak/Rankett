import SwiftUI
import UIKit

struct StudyView: UIViewRepresentable {
        let studyResult: StudyResult?
        
        func makeUIView(context: Context) -> StudyGraphView {
                let view = StudyGraphView()
                view.backgroundColor = .black
                view.isOpaque = true
                view.contentMode = .redraw  // Add this line
                return view
        }
        
        func updateUIView(_ uiView: StudyGraphView, context: Context) {
                uiView.studyResult = studyResult
                uiView.setNeedsDisplay()
        }
}

final class StudyGraphView: UIView {
        var studyResult: StudyResult?
        
        override func draw(_ rect: CGRect) {
                guard let ctx = UIGraphicsGetCurrentContext(),
                      let result = studyResult else { return }
                
                let padding: CGFloat = 40  // Increased for scale labels
                let width = rect.width - 2 * padding
                let height = rect.height - 2 * padding
                
                // Draw background
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(rect)
                
                // Convert magnitude data to dB if needed
                let originalDB = result.originalSpectrum.map { mag in
                        20 * log10(max(mag, 1e-10))  // Convert to dB
                }
                let noiseFloorDB = result.noiseFloor.map { mag in
                        20 * log10(max(mag, 1e-10))  // Convert to dB
                }
                
                // Calculate actual dB range from data
                let allValues = originalDB + noiseFloorDB
                let minDB = allValues.min() ?? -80
                let maxDB = allValues.max() ?? 0
                let dbRange = maxDB - minDB
                
                // Draw grid with calculated range
                drawGrid(ctx: ctx, rect: rect, padding: padding, minDB: minDB, maxDB: maxDB)
                
                ctx.saveGState()
                ctx.translateBy(x: padding, y: padding)
                
                // Calculate frequency range for x-axis scaling
                let minFreq: Float = 20.0
                let maxFreq: Float = 20000.0
                let useLogScale = true
                
                // Draw original spectrum (blue, semi-transparent)
                drawSpectrumCurve(ctx: ctx,
                                  data: originalDB,
                                  frequencies: result.frequencies,
                                  width: width, height: height,
                                  minDB: minDB, dbRange: dbRange,
                                  minFreq: minFreq, maxFreq: maxFreq,
                                  useLogScale: useLogScale,
                                  color: UIColor.systemBlue.withAlphaComponent(0.5))
                
                // Draw noise floor (red)
                drawSpectrumCurve(ctx: ctx,
                                  data: noiseFloorDB,
                                  frequencies: result.frequencies,
                                  width: width, height: height,
                                  minDB: minDB, dbRange: dbRange,
                                  minFreq: minFreq, maxFreq: maxFreq,
                                  useLogScale: useLogScale,
                                  color: UIColor.systemRed)
                
                // Draw denoised spectrum (green)
                drawDenoisedSpectrum(ctx: ctx,
                                     original: originalDB,
                                     noiseFloor: noiseFloorDB,
                                     frequencies: result.frequencies,
                                     width: width, height: height,
                                     minDB: minDB, dbRange: dbRange,
                                     minFreq: minFreq, maxFreq: maxFreq,
                                     useLogScale: useLogScale,
                                     color: UIColor.systemGreen)
                
                // Draw HPS if available
                if let hps = result.hpsSpectrum {
                        drawSpectrumCurve(ctx: ctx,
                                          data: hps,
                                          frequencies: result.frequencies,
                                          width: width, height: height,
                                          minDB: minDB, dbRange: dbRange,
                                          minFreq: minFreq, maxFreq: maxFreq,
                                          useLogScale: useLogScale,
                                          color: UIColor.systemPurple)
                }
                
                // Draw peak markers
                drawPeaks(ctx: ctx,
                          peaks: result.peaks,
                          originalDB: originalDB,
                          frequencies: result.frequencies,
                          width: width, height: height,
                          minDB: minDB, dbRange: dbRange,
                          minFreq: minFreq, maxFreq: maxFreq,
                          useLogScale: useLogScale)
                
                ctx.restoreGState()
                
                // Draw legend
                drawLegend(ctx: ctx, rect: rect, padding: padding, hasHPS: result.hpsSpectrum != nil)
        }
        
        private func drawSpectrumCurve(ctx: CGContext,
                                       data: [Float],
                                       frequencies: [Float],
                                       width: CGFloat, height: CGFloat,
                                       minDB: Float, dbRange: Float,
                                       minFreq: Float, maxFreq: Float,
                                       useLogScale: Bool,
                                       color: UIColor) {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(0.8)
                
                let path = CGMutablePath()
                var started = false
                
                for (i, value) in data.enumerated() {
                        let freq = frequencies[i]
                        
                        // Skip frequencies outside our display range
                        guard freq >= minFreq && freq <= maxFreq else { continue }
                        
                        // Calculate x position based on frequency scale
                        let x: CGFloat
                        if useLogScale {
                                let logMin = log10(minFreq)
                                let logMax = log10(maxFreq)
                                let logFreq = log10(freq)
                                x = (CGFloat(logFreq - logMin) / CGFloat(logMax - logMin)) * width
                        } else {
                                x = CGFloat((freq - minFreq) / (maxFreq - minFreq)) * width
                        }
                        
                        // Calculate y position
                        let normalizedValue = (value - minDB) / dbRange
                        let y = height * (1 - CGFloat(max(0, min(1, normalizedValue))))
                        
                        if !started {
                                path.move(to: CGPoint(x: x, y: y))
                                started = true
                        } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                        }
                }
                
                ctx.addPath(path)
                ctx.strokePath()
        }
        
        private func drawDenoisedSpectrum(ctx: CGContext,
                                          original: [Float],
                                          noiseFloor: [Float],
                                          frequencies: [Float],
                                          width: CGFloat, height: CGFloat,
                                          minDB: Float, dbRange: Float,
                                          minFreq: Float, maxFreq: Float,
                                          useLogScale: Bool,
                                          color: UIColor) {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(0.8)
                ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)
                
                let path = CGMutablePath()
                let fillPath = CGMutablePath()
                var started = false
                
                for (i, originalValue) in original.enumerated() {
                        let freq = frequencies[i]
                        guard freq >= minFreq && freq <= maxFreq else { continue }
                        
                        // Only draw where signal is above noise floor
                        if originalValue > noiseFloor[i] {
                                let x: CGFloat
                                if useLogScale {
                                        let logMin = log10(minFreq)
                                        let logMax = log10(maxFreq)
                                        let logFreq = log10(freq)
                                        x = (CGFloat(logFreq - logMin) / CGFloat(logMax - logMin)) * width
                                } else {
                                        x = CGFloat((freq - minFreq) / (maxFreq - minFreq)) * width
                                }
                                
                                let normalizedValue = (originalValue - minDB) / dbRange
                                let y = height * (1 - CGFloat(max(0, min(1, normalizedValue))))
                                
                                if !started {
                                        path.move(to: CGPoint(x: x, y: y))
                                        fillPath.move(to: CGPoint(x: x, y: height))
                                        fillPath.addLine(to: CGPoint(x: x, y: y))
                                        started = true
                                } else {
                                        path.addLine(to: CGPoint(x: x, y: y))
                                        fillPath.addLine(to: CGPoint(x: x, y: y))
                                }
                        }
                }
                
                if started {
                        fillPath.addLine(to: CGPoint(x: width, y: height))
                        fillPath.closeSubpath()
                        
                        ctx.addPath(fillPath)
                        ctx.fillPath()
                        
                        ctx.addPath(path)
                        ctx.strokePath()
                }
        }
        
        private func drawPeaks(ctx: CGContext,
                               peaks: [Peak],
                               originalDB: [Float],  // Added this parameter
                               frequencies: [Float],
                               width: CGFloat, height: CGFloat,
                               minDB: Float, dbRange: Float,
                               minFreq: Float, maxFreq: Float,
                               useLogScale: Bool) {
                ctx.setFillColor(UIColor.systemYellow.cgColor)
                
                for peak in peaks {
                        let freq = peak.frequency
                        guard freq >= minFreq && freq <= maxFreq else { continue }
                        
                        let x: CGFloat
                        if useLogScale {
                                let logMin = log10(minFreq)
                                let logMax = log10(maxFreq)
                                let logFreq = log10(freq)
                                x = (CGFloat(logFreq - logMin) / CGFloat(logMax - logMin)) * width
                        } else {
                                x = CGFloat((freq - minFreq) / (maxFreq - minFreq)) * width
                        }
                        
                        // Use the actual magnitude from originalDB at the peak index
                        let peakMagnitudeDB = originalDB[peak.index]
                        let normalizedValue = (peakMagnitudeDB - minDB) / dbRange
                        let y = height * (1 - CGFloat(max(0, min(1, normalizedValue))))
                        
                        // Draw circle at peak
                        ctx.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
                        
                        // Draw frequency label
                        let attributes: [NSAttributedString.Key: Any] = [
                                .font: UIFont.systemFont(ofSize: 9),
                                .foregroundColor: UIColor.systemYellow
                        ]
                        let freqText = String(format: "%.0f Hz", peak.frequency)
                        freqText.draw(at: CGPoint(x: x - 20, y: y - 15), withAttributes: attributes)
                }
        }
        
        private func drawLegend(ctx: CGContext, rect: CGRect, padding: CGFloat, hasHPS: Bool) {
                let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 10),
                        .foregroundColor: UIColor.white
                ]
                
                var legendItems = [
                        ("Original", UIColor.systemBlue.withAlphaComponent(0.5)),
                        ("Noise Floor", UIColor.systemRed),
                        ("Denoised", UIColor.systemGreen),
                        ("Peaks", UIColor.systemYellow)
                ]
                
                // Add HPS to legend if present
                if hasHPS {
                        legendItems.append(("HPS", UIColor.systemPurple))
                }
                
                var x = padding
                let y: CGFloat = 5
                
                for (text, color) in legendItems {
                        // Draw color indicator
                        ctx.setFillColor(color.cgColor)
                        ctx.fill(CGRect(x: x, y: y + 2, width: 15, height: 2))
                        
                        x += 20
                        
                        // Draw text
                        text.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
                        
                        let textSize = text.size(withAttributes: attributes)
                        x += textSize.width + 15
                }
        }
        
        private func drawGrid(ctx: CGContext, rect: CGRect, padding: CGFloat, minDB: Float, maxDB: Float) {
                ctx.saveGState()
                
                let width = rect.width - 2 * padding
                let height = rect.height - 2 * padding
                
                ctx.setStrokeColor(UIColor.systemGray.withAlphaComponent(0.2).cgColor)
                ctx.setLineWidth(0.5)
                
                // Draw horizontal lines (dB scale) - dynamically based on range
                let dbRange = maxDB - minDB
                let dbStep: Float = dbRange > 60 ? 20 : 10
                
                var db = floor(minDB / dbStep) * dbStep
                while db <= ceil(maxDB / dbStep) * dbStep {
                        if db >= minDB && db <= maxDB {
                                let y = padding + height * CGFloat(1 - (db - minDB) / dbRange)
                                ctx.move(to: CGPoint(x: padding, y: y))
                                ctx.addLine(to: CGPoint(x: rect.width - padding, y: y))
                                
                                // Draw label
                                let attributes: [NSAttributedString.Key: Any] = [
                                        .font: UIFont.systemFont(ofSize: 9),
                                        .foregroundColor: UIColor.systemGray
                                ]
                                "\(Int(db)) dB".draw(at: CGPoint(x: 2, y: y - 5), withAttributes: attributes)
                        }
                        db += dbStep
                }
                
                // Draw vertical lines (frequency scale)
                let freqLines: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
                for freq in freqLines {
                        let logMin = log10(20.0)
                        let logMax = log10(20000.0)
                        let logFreq = log10(freq)
                        let x = padding + CGFloat((logFreq - logMin) / (logMax - logMin)) * width
                        
                        ctx.move(to: CGPoint(x: x, y: padding))
                        ctx.addLine(to: CGPoint(x: x, y: rect.height - padding))
                        
                        // Draw label
                        let attributes: [NSAttributedString.Key: Any] = [
                                .font: UIFont.systemFont(ofSize: 9),
                                .foregroundColor: UIColor.systemGray
                        ]
                        let label = freq >= 1000 ? "\(Int(freq/1000))k" : "\(Int(freq))"
                        label.draw(at: CGPoint(x: x - 10, y: rect.height - padding + 2), withAttributes: attributes)
                }
                
                ctx.strokePath()
                ctx.restoreGState()
        }
}
