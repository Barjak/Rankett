import SwiftUI
import UIKit

struct StudyView: UIViewRepresentable {
        let studyResult: StudyResult?
        
        func makeUIView(context: Context) -> StudyGraphView {
                let view = StudyGraphView()
                view.backgroundColor = .black
                view.isOpaque = true
                view.contentMode = .redraw
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
                
                // Remove horizontal padding to fill screen width
                let verticalPadding: CGFloat = 40
                let width = rect.width
                let height = rect.height - 2 * verticalPadding
                
                // Draw background
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(rect)
                
                // Data is already in dB - no conversion needed
                let originalDB = result.originalSpectrum
                let noiseFloorDB = result.noiseFloor
                let denoisedDB = result.denoisedSpectrum
                
                // Calculate dB range from data
                let allValues = originalDB + noiseFloorDB
                let validValues = allValues.filter { $0 > -200 }  // Filter out extreme values
                let minDB = max(validValues.min() ?? -80, -80)  // Clamp minimum to -80 dB
                let maxDB = min(validValues.max() ?? 0, 20)     // Clamp maximum to 20 dB
                let dbRange = maxDB - minDB
                
                print("StudyView: dB range: \(minDB) to \(maxDB)")
                
                // Draw grid
                drawGrid(ctx: ctx, rect: rect, verticalPadding: verticalPadding, minDB: minDB, maxDB: maxDB)
                
                ctx.saveGState()
                ctx.translateBy(x: 0, y: verticalPadding)
                
                // Draw curves without additional dB conversion
                drawSpectrumCurve(ctx: ctx,
                                  data: originalDB,
                                  frequencies: result.frequencies,
                                  width: width, height: height,
                                  minDB: minDB, dbRange: dbRange,
                                  color: UIColor.systemBlue.withAlphaComponent(0.5))
                
                drawSpectrumCurve(ctx: ctx,
                                  data: noiseFloorDB,
                                  frequencies: result.frequencies,
                                  width: width, height: height,
                                  minDB: minDB, dbRange: dbRange,
                                  color: UIColor.systemRed)
                
                drawDenoisedSpectrum(ctx: ctx,
                                     denoisedDB: denoisedDB,
                                     frequencies: result.frequencies,
                                     width: width, height: height,
                                     minDB: minDB, dbRange: dbRange,
                                     color: UIColor.systemGreen)
                
                drawPeaks(ctx: ctx,
                          peaks: result.peaks,
                          frequencies: result.frequencies,
                          width: width, height: height,
                          minDB: minDB, dbRange: dbRange)
                
                ctx.restoreGState()
                
                // Draw legend
                drawLegend(ctx: ctx, rect: rect, verticalPadding: verticalPadding)
        }
        
        private func drawSpectrumCurve(ctx: CGContext,
                                       data: [Float],
                                       frequencies: [Float],
                                       width: CGFloat, height: CGFloat,
                                       minDB: Float, dbRange: Float,
                                       color: UIColor) {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(0.8)
                
                let path = CGMutablePath()
                
                for (i, value) in data.enumerated() {
                        let x = CGFloat(i) * width / CGFloat(data.count - 1)
                        let clampedValue = max(minDB, min(minDB + dbRange, value))
                        let normalizedValue = (clampedValue - minDB) / dbRange
                        let y = height * (1 - CGFloat(normalizedValue))
                        
                        if i == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                        } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                        }
                }
                
                ctx.addPath(path)
                ctx.strokePath()
        }
        
        private func drawDenoisedSpectrum(ctx: CGContext,
                                          denoisedDB: [Float],
                                          frequencies: [Float],
                                          width: CGFloat, height: CGFloat,
                                          minDB: Float, dbRange: Float,
                                          color: UIColor) {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(0.8)
                ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)
                
                let path = CGMutablePath()
                let fillPath = CGMutablePath()
                var started = false
                
                for (i, value) in denoisedDB.enumerated() {
                        // Only draw where signal is above noise floor (-80 dB threshold)
                        if value > -80 {
                                let x = CGFloat(i) * width / CGFloat(denoisedDB.count - 1)
                                
                                let clampedValue = max(minDB, min(minDB + dbRange, value))
                                let normalizedValue = (clampedValue - minDB) / dbRange
                                let y = height * (1 - CGFloat(normalizedValue))
                                
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
                               frequencies: [Float],
                               width: CGFloat, height: CGFloat,
                               minDB: Float, dbRange: Float) {
                ctx.setFillColor(UIColor.systemYellow.cgColor)
                
                for peak in peaks {
                        let x = CGFloat(peak.index) * width / CGFloat(frequencies.count - 1)
                        
                        // Use the peak's magnitude directly (already in dB)
                        let clampedValue = max(minDB, min(minDB + dbRange, peak.magnitude))
                        let normalizedValue = (clampedValue - minDB) / dbRange
                        let y = height * (1 - CGFloat(normalizedValue))
                        
                        // Draw circle at peak
                        ctx.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
                        
                        // Draw frequency label
                        let attributes: [NSAttributedString.Key: Any] = [
                                .font: UIFont.systemFont(ofSize: 9),
                                .foregroundColor: UIColor.systemYellow
                        ]
                        let freqText = String(format: "%.0f Hz", peak.frequency)
                        let textSize = freqText.size(withAttributes: attributes)
                        let textX = min(max(x - textSize.width/2, 5), width - textSize.width - 5)
                        freqText.draw(at: CGPoint(x: textX, y: y - 15), withAttributes: attributes)
                }
        }
        
        private func drawLegend(ctx: CGContext, rect: CGRect, verticalPadding: CGFloat) {
                let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 10),
                        .foregroundColor: UIColor.white
                ]
                
                let legendItems = [
                        ("Original", UIColor.systemBlue.withAlphaComponent(0.5)),
                        ("Noise Floor", UIColor.systemRed),
                        ("Denoised", UIColor.systemGreen),
                        ("Peaks", UIColor.systemYellow)
                ]
                
                var x: CGFloat = 10  // Small left margin
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
        
        private func drawGrid(ctx: CGContext, rect: CGRect, verticalPadding: CGFloat, minDB: Float, maxDB: Float) {
                ctx.saveGState()
                
                let width = rect.width
                let height = rect.height - 2 * verticalPadding
                
                ctx.setStrokeColor(UIColor.systemGray.withAlphaComponent(0.2).cgColor)
                ctx.setLineWidth(0.5)
                
                // Draw horizontal lines (dB scale)
                let dbRange = maxDB - minDB
                let dbStep: Float = dbRange > 60 ? 20 : 10
                
                var db = floor(minDB / dbStep) * dbStep
                while db <= ceil(maxDB / dbStep) * dbStep {
                        if db >= minDB && db <= maxDB {
                                let y = verticalPadding + height * CGFloat(1 - (db - minDB) / dbRange)
                                ctx.move(to: CGPoint(x: 0, y: y))
                                ctx.addLine(to: CGPoint(x: rect.width, y: y))
                                
                                // Draw label
                                let attributes: [NSAttributedString.Key: Any] = [
                                        .font: UIFont.systemFont(ofSize: 9),
                                        .foregroundColor: UIColor.systemGray
                                ]
                                "\(Int(db)) dB".draw(at: CGPoint(x: 2, y: y - 5), withAttributes: attributes)
                        }
                        db += dbStep
                }
                
                // Draw vertical lines (frequency scale) - log spaced
                let freqLines: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
                let logMin = log10(20.0)
                let logMax = log10(20000.0)
                
                for freq in freqLines {
                        let logFreq = log10(freq)
                        let normalizedX = CGFloat((logFreq - logMin) / (logMax - logMin))
                        let x = normalizedX * width
                        
                        ctx.move(to: CGPoint(x: x, y: verticalPadding))
                        ctx.addLine(to: CGPoint(x: x, y: rect.height - verticalPadding))
                        
                        // Draw label
                        let attributes: [NSAttributedString.Key: Any] = [
                                .font: UIFont.systemFont(ofSize: 9),
                                .foregroundColor: UIColor.systemGray
                        ]
                        let label = freq >= 1000 ? "\(Int(freq/1000))k" : "\(Int(freq))"
                        let textSize = label.size(withAttributes: attributes)
                        label.draw(at: CGPoint(x: x - textSize.width/2, y: rect.height - verticalPadding + 2), withAttributes: attributes)
                }
                
                ctx.strokePath()
                ctx.restoreGState()
        }
}
