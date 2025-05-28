import SwiftUI
import UIKit

struct SpectrumView: UIViewRepresentable {
    let spectrumData: [Float]
    let config: Config
    
    func makeUIView(context: Context) -> SpectrumGraphView {
        let view = SpectrumGraphView()
        view.backgroundColor = .black
        view.isOpaque = true
        return view
    }
    
    func updateUIView(_ uiView: SpectrumGraphView, context: Context) {
        uiView.spectrumData = spectrumData
        uiView.config = config
        uiView.setNeedsDisplay()
    }
}

final class SpectrumGraphView: UIView {
    var spectrumData: [Float] = []
    var config = Config()
    
    // Pre-calculate frequency labels for efficiency
    private lazy var frequencyLabels: [(frequency: Float, x: CGFloat)] = {
        guard config.useLogFrequencyScale else { return [] }
        
        let frequencies: [Float] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        return frequencies.compactMap { freq in
            guard freq >= Float(config.minFrequency) && freq <= Float(config.maxFrequency) else { return nil }
            let logMin = log10(Float(config.minFrequency))
            let logMax = log10(Float(config.maxFrequency))
            let logFreq = log10(freq)
            let x = (logFreq - logMin) / (logMax - logMin)
            return (freq, CGFloat(x))
        }
    }()
    
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              !spectrumData.isEmpty else { return }
        
        let padding: CGFloat = 20
        let width = rect.width - 2 * padding
        let height = rect.height - 2 * padding
        
        // Draw grid
        drawGrid(ctx: ctx, rect: rect, padding: padding)
        
        // Draw spectrum
        ctx.saveGState()
        ctx.translateBy(x: padding, y: padding)
        ctx.setStrokeColor(UIColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        
        // Create path
        let path = CGMutablePath()
        let minDB: Float = -80
        let maxDB: Float = 60
        let dbRange = maxDB - minDB
        
        for (i, magnitude) in spectrumData.enumerated() {
            let x = CGFloat(i) * width / CGFloat(spectrumData.count - 1)
            let normalizedMag = (magnitude - minDB) / dbRange
            let y = height * (1 - CGFloat(max(0, min(1, normalizedMag))))
            
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }
    
    private func drawGrid(ctx: CGContext, rect: CGRect, padding: CGFloat) {
        ctx.saveGState()
        
        let width = rect.width - 2 * padding
        let height = rect.height - 2 * padding
        
        // Grid style
        ctx.setStrokeColor(UIColor.systemGray.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [2, 2])
        
        // Draw horizontal lines (dB scale)
        let dbLines: [(db: Float, alpha: CGFloat)] = [
            (0, 0.5), (-20, 0.3), (-40, 0.3), (-60, 0.3), (-80, 0.5)
        ]
        
        for (db, alpha) in dbLines {
            ctx.setStrokeColor(UIColor.systemGray.withAlphaComponent(alpha).cgColor)
            let y = padding + height * CGFloat(1 + db / 80)
            ctx.move(to: CGPoint(x: padding, y: y))
            ctx.addLine(to: CGPoint(x: rect.width - padding, y: y))
            ctx.strokePath()
        }
        
        // Draw vertical lines (frequency scale)
        if config.useLogFrequencyScale {
            for (_, normalizedX) in frequencyLabels {
                let x = padding + normalizedX * width
                ctx.move(to: CGPoint(x: x, y: padding))
                ctx.addLine(to: CGPoint(x: x, y: rect.height - padding))
            }
            ctx.strokePath()
        }
        
        // Draw labels
        ctx.setLineDash(phase: 0, lengths: [])
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.systemGray
        ]
        
        // dB labels
        for (db, _) in dbLines {
            let text = "\(Int(db)) dB"
            let size = text.size(withAttributes: attributes)
            let y = padding + height * CGFloat(1 + db / 80) - size.height / 2
            text.draw(at: CGPoint(x: 2, y: y), withAttributes: attributes)
        }
        
        // Frequency labels
        if config.useLogFrequencyScale {
            for (freq, normalizedX) in frequencyLabels {
                let text = freq >= 1000 ? "\(Int(freq/1000))k" : "\(Int(freq))"
                let size = text.size(withAttributes: attributes)
                let x = padding + normalizedX * width - size.width / 2
                text.draw(at: CGPoint(x: x, y: rect.height - padding + 2), withAttributes: attributes)
            }
        }
        
        ctx.restoreGState()
    }
}
