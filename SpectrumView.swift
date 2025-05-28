import SwiftUI
import AVFoundation
import Accelerate
import Foundation

// MARK: - SwiftUI Wrapper
struct SpectrumView: UIViewRepresentable {
    let spectrumData: [Float]
    let frequencyData: [Float]
    let config: SpectrumAnalyzerConfig
    
    func makeUIView(context: Context) -> SpectrumGraphView {
        let view = SpectrumGraphView()
        view.backgroundColor = .black
        return view
    }
    
    func updateUIView(_ uiView: SpectrumGraphView, context: Context) {
        uiView.spectrumData = spectrumData
        uiView.frequencyData = frequencyData
        uiView.config = config
        uiView.setNeedsDisplay()
    }
}

class SpectrumGraphView: UIView {
    var spectrumData: [Float] = []
    var frequencyData: [Float] = []
    var config = SpectrumAnalyzerConfig()

    override func draw(_ rect: CGRect) {
        guard spectrumData.count > 1,
              spectrumData.count == frequencyData.count,
              let ctx = UIGraphicsGetCurrentContext() else {
            return
        }

        let minDB: Float = -160
        let maxDB: Float = 100
        let dbRange = maxDB - minDB

        let padding: CGFloat = 20
        let width = rect.width - 2 * padding
        let height = rect.height - 2 * padding

        ctx.setStrokeColor(UIColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.beginPath()

        for i in 0..<spectrumData.count {
            let freq = Double(frequencyData[i])
            if config.useLogFrequencyScale &&
                (freq < config.minFrequency || freq > config.maxFrequency) {
                continue
            }

            let x: CGFloat = {
                if config.useLogFrequencyScale {
                    let logMin = log10(config.minFrequency)
                    let logMax = log10(config.maxFrequency)
                    let logFreq = log10(freq)
                    let normalizedX = (logFreq - logMin) / (logMax - logMin)
                    return padding + CGFloat(normalizedX) * width
                } else {
                    return padding + CGFloat(i) * width / CGFloat(spectrumData.count - 1)
                }
            }()

            let db = max(minDB, min(maxDB, spectrumData[i]))
            let normalizedY = (db - minDB) / dbRange
            let y = padding + height * (1 - CGFloat(normalizedY))

            if i == 0 {
                ctx.move(to: CGPoint(x: x, y: y))
            } else {
                ctx.addLine(to: CGPoint(x: x, y: y))
            }
        }

        ctx.strokePath()
        drawGrid(ctx: ctx, rect: rect, padding: padding)
    }

    private func drawGrid(ctx: CGContext, rect: CGRect, padding: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.gray.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(1)

        // Draw horizontal dB lines
        let dbSteps: [Float] = [-20, -40, -60, -80, -100]
        let height = rect.height - 2 * padding
        for db in dbSteps {
            let norm = (db - (-160)) / 260
            let y = padding + height * (1 - CGFloat(norm))
            ctx.move(to: CGPoint(x: padding, y: y))
            ctx.addLine(to: CGPoint(x: rect.width - padding, y: y))
        }

        ctx.strokePath()
        ctx.restoreGState()
    }
}
