import SwiftUI
import UIKit

struct StudyView: UIViewRepresentable {
    let studyResult: StudyResult?
    
    func makeUIView(context: Context) -> StudyGraphView {
        let view = StudyGraphView()
        view.backgroundColor = .black
        view.isOpaque = true
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
        
        let padding: CGFloat = 20
        let width = rect.width - 2 * padding
        let height = rect.height - 2 * padding
        
        // Draw background
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(rect)
        
        // Draw grid
        drawGrid(ctx: ctx, rect: rect, padding: padding)
        
        ctx.saveGState()
        ctx.translateBy(x: padding, y: padding)
        
        let minDB: Float = -80
        let maxDB: Float = 20
        let dbRange = maxDB - minDB
        
        // Draw noise floor (red)
        drawCurve(ctx: ctx, data: result.noiseFloor,
                 width: width, height: height,
                 minDB: minDB, dbRange: dbRange,
                 color: UIColor.systemRed.withAlphaComponent(0.7))
        
        // Draw denoised spectrum (green)
        drawCurve(ctx: ctx, data: result.denoisedSpectrum,
                 width: width, height: height,
                 minDB: minDB, dbRange: dbRange,
                 color: UIColor.systemGreen)
        
        ctx.restoreGState()
        
        // Draw title
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: UIColor.white
        ]
        "Denoised Spectrum".draw(at: CGPoint(x: padding, y: 2), withAttributes: attributes)
    }
    
    private func drawCurve(ctx: CGContext, data: [Float],
                          width: CGFloat, height: CGFloat,
                          minDB: Float, dbRange: Float,
                          color: UIColor) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.5)
        
        let path = CGMutablePath()
        
        for (i, value) in data.enumerated() {
            let x = CGFloat(i) * width / CGFloat(data.count - 1)
            let normalizedValue = (value - minDB) / dbRange
            let y = height * (1 - CGFloat(max(0, min(1, normalizedValue))))
            
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        
        ctx.addPath(path)
        ctx.strokePath()
    }
    
    private func drawGrid(ctx: CGContext, rect: CGRect, padding: CGFloat) {
        ctx.saveGState()
        
        let width = rect.width - 2 * padding
        let height = rect.height - 2 * padding
        
        ctx.setStrokeColor(UIColor.systemGray.withAlphaComponent(0.2).cgColor)
        ctx.setLineWidth(0.5)
        
        // Draw horizontal lines
        for i in 0...4 {
            let y = padding + CGFloat(i) * height / 4
            ctx.move(to: CGPoint(x: padding, y: y))
            ctx.addLine(to: CGPoint(x: rect.width - padding, y: y))
        }
        
        // Draw vertical lines
        for i in 0...4 {
            let x = padding + CGFloat(i) * width / 4
            ctx.move(to: CGPoint(x: x, y: padding))
            ctx.addLine(to: CGPoint(x: x, y: rect.height - padding))
        }
        
        ctx.strokePath()
        ctx.restoreGState()
    }
}
