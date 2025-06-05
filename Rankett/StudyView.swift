import SwiftUI
import UIKit

// MARK: - Simple Plot Data Structure
struct Plot {
        var current: [Float] = []
        var target: [Float] = []
        let color: UIColor
        let name: String
        let lineWidth: CGFloat
        
        mutating func smooth(_ factor: Float) {
                guard current.count == target.count else {
                        current = target
                        return
                }
                let beta = 1.0 - factor
                for i in 0..<current.count {
                        current[i] = current[i] * factor + target[i] * beta
                }
        }
}

// MARK: - Main View
struct StudyView: UIViewRepresentable {
        @ObservedObject var study: Study
        @ObservedObject var store: TuningParameterStore
        
        func makeUIView(context: Context) -> StudyGraphView {
                let view = StudyGraphView(store: store)
                view.backgroundColor = .black
                view.isOpaque = true
                view.contentMode = .redraw
                return view
        }
        
        func updateUIView(_ uiView: StudyGraphView, context: Context) {
                uiView.updateTargets(
                        originalSpectrum: study.targetOriginalSpectrum,
                        noiseFloor: study.targetNoiseFloor,
                        denoisedSpectrum: study.targetDenoisedSpectrum,
                        frequencies: study.targetFrequencies,
                        hpsSpectrum: study.targetHPSSpectrum,
                        hpsFundamental: study.targetHPSFundamental
                )
                uiView.setNeedsDisplay()
        }
}

final class StudyGraphView: UIView {
        private let store: TuningParameterStore
        private var displayTimer: Timer?
        
        // Pre-allocated plots
        private var plots: [Plot] = [
                Plot(color: .systemBlue.withAlphaComponent(0.5), name: "Original", lineWidth: 0.8),
                Plot(color: .systemRed, name: "Noise Floor", lineWidth: 0.8),
                Plot(color: .systemGreen, name: "Denoised", lineWidth: 0.8),
                Plot(color: .systemPurple, name: "HPS", lineWidth: 0.5)
        ]
        
        // Special HPS data
        private var hpsFundamental: Float = 0
        private var targetHPSFundamental: Float = 0
        
        private var frequencies: [Float] = []
        private var binMapper: BinMapper?
        private let dataLock = NSLock()
        
        // Drawing constants from store
        private var padding: CGFloat { 40 }
        private var minDB: Float { -80 }
        private var maxDB: Float { 180 }
        
        init(store: TuningParameterStore) {
                self.store = store
                super.init(frame: .zero)
                setupTimer()
        }
        
        @available(*, unavailable)
        required init?(coder: NSCoder) {
                fatalError("Use init(store:)")
        }
        
        deinit {
                displayTimer?.invalidate()
        }
        
        private func setupTimer() {
                displayTimer = Timer.scheduledTimer(
                        withTimeInterval: store.frameInterval,
                        repeats: true
                ) { [weak self] _ in
                        self?.updateDisplay()
                }
        }
        
        func updateTargets(originalSpectrum: [Float], noiseFloor: [Float],
                           denoisedSpectrum: [Float], frequencies: [Float],
                           hpsSpectrum: [Float], hpsFundamental: Float) {
                dataLock.lock()
                defer { dataLock.unlock() }
                
                guard !originalSpectrum.isEmpty else { return }
                
                // Update bin mapper if needed
                if binMapper == nil || binMapper?.binFrequencies.count != store.downscaleBinCount {
                        binMapper = BinMapper(store: store, halfSize: originalSpectrum.count)
                }
                
                guard let mapper = binMapper else { return }
                
                // Map all spectra to display bins
                plots[0].target = mapper.mapSpectrum(originalSpectrum)
                plots[1].target = mapper.mapSpectrum(noiseFloor)
                plots[2].target = mapper.mapSpectrum(denoisedSpectrum)
                plots[3].target = mapper.mapHPSSpectrum(hpsSpectrum)
                
                self.frequencies = mapper.binFrequencies
                self.targetHPSFundamental = hpsFundamental
                
                // Initialize current if empty
                for i in 0..<plots.count {
                        if plots[i].current.isEmpty {
                                plots[i].current = plots[i].target
                        }
                }
        }
        
        private func updateDisplay() {
                dataLock.lock()
                
                // Smooth all plots
                let factor = store.animationSmoothingFactor
                for i in 0..<plots.count {
                        plots[i].smooth(factor)
                }
                
                // Smooth HPS fundamental
                let beta = 1.0 - factor
                hpsFundamental = hpsFundamental * factor + targetHPSFundamental * beta
                
                dataLock.unlock()
                setNeedsDisplay()
        }
        
        override func draw(_ rect: CGRect) {
                guard let ctx = UIGraphicsGetCurrentContext() else { return }
                
                dataLock.lock()
                let plotData = plots.map { ($0.current, $0.color, $0.lineWidth) }
                let freq = frequencies
                let fundamental = hpsFundamental
                dataLock.unlock()
                
                guard !freq.isEmpty else { return }
                
                // Drawing setup
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(rect)
                
                let drawRect = CGRect(x: 0, y: padding,
                                      width: rect.width - padding,
                                      height: rect.height - 2 * padding)
                
                // Draw grid
                drawGrid(ctx: ctx, in: rect)
                
                // Draw all plots
                ctx.saveGState()
                ctx.translateBy(x: 0, y: padding)
                
                for (data, color, lineWidth) in plotData {
                        drawSpectrum(ctx: ctx, data: data, frequencies: freq,
                                     in: drawRect, color: color, lineWidth: lineWidth)
                }
                
                // Draw HPS fundamental marker
                if fundamental > Float(store.renderMinFrequency) &&
                        fundamental < Float(store.renderMaxFrequency) {
                        drawFundamentalMarker(ctx: ctx, frequency: fundamental,
                                              in: drawRect, color: plots[3].color)
                }
                
                ctx.restoreGState()
                
                // Draw legend
                drawLegend(ctx: ctx, at: CGPoint(x: 10, y: 5))
        }
        
        private func drawSpectrum(ctx: CGContext, data: [Float], frequencies: [Float],
                                  in rect: CGRect, color: UIColor, lineWidth: CGFloat) {
                guard data.count == frequencies.count else { return }
                
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(lineWidth)
                
                let path = CGMutablePath()
                var started = false
                
                for (i, value) in data.enumerated() {
                        let freq = frequencies[i]
                        guard freq >= Float(store.renderMinFrequency),
                                freq <= Float(store.renderMaxFrequency) else { continue }
                        
                        let x: CGFloat
                        if store.renderWithLogFrequencyScale {
                                let logMin = log10(store.renderMinFrequency)
                                let logMax = log10(store.renderMaxFrequency)
                                let logFreq = log10(Double(freq))
                                x = CGFloat((logFreq - logMin) / (logMax - logMin)) * rect.width
                        } else {
                                x = CGFloat(i) * rect.width / CGFloat(data.count - 1)
                        }
                        
                        let normalizedValue = (value - minDB) / (maxDB - minDB)
                        let y = rect.height * (1 - CGFloat(normalizedValue))
                        
                        if started {
                                path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                                path.move(to: CGPoint(x: x, y: y))
                                started = true
                        }
                }
                
                ctx.addPath(path)
                ctx.strokePath()
        }
        
        private func drawFundamentalMarker(ctx: CGContext, frequency: Float,
                                           in rect: CGRect, color: UIColor) {
                let logMin = log10(store.renderMinFrequency)
                let logMax = log10(store.renderMaxFrequency)
                let logFreq = log10(Double(frequency))
                let x = CGFloat((logFreq - logMin) / (logMax - logMin)) * rect.width
                
                // Vertical line
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(0.3)
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: rect.height))
                ctx.strokePath()
                
                // Label
                let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.boldSystemFont(ofSize: 11),
                        .foregroundColor: color
                ]
                String(format: "F₀: %.0f Hz", frequency)
                        .draw(at: CGPoint(x: x + 5, y: 5), withAttributes: attributes)
        }
        
        private func drawGrid(ctx: CGContext, in rect: CGRect) {
                ctx.setStrokeColor(UIColor.systemGray.withAlphaComponent(0.2).cgColor)
                ctx.setLineWidth(0.5)
                
                let height = rect.height - 2 * padding
                
                // dB lines
                let dbStep: Float = 20
                var db = ceil(minDB / dbStep) * dbStep
                while db <= floor(maxDB / dbStep) * dbStep {
                        let y = padding + height * CGFloat(1 - (db - minDB) / (maxDB - minDB))
                        ctx.move(to: CGPoint(x: 0, y: y))
                        ctx.addLine(to: CGPoint(x: rect.width, y: y))
                        
                        let attributes: [NSAttributedString.Key: Any] = [
                                .font: UIFont.systemFont(ofSize: 9),
                                .foregroundColor: UIColor.systemGray
                        ]
                        "\(Int(db)) dB".draw(at: CGPoint(x: 2, y: y - 5), withAttributes: attributes)
                        db += dbStep
                }
                
                // Frequency lines
                let freqLines: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
                let logMin = log10(store.renderMinFrequency)
                let logMax = log10(store.renderMaxFrequency)
                
                for freq in freqLines {
                        guard freq >= store.renderMinFrequency,
                                freq <= store.renderMaxFrequency else { continue }
                        
                        let x = CGFloat((log10(freq) - logMin) / (logMax - logMin)) * (rect.width - padding)
                        ctx.move(to: CGPoint(x: x, y: padding))
                        ctx.addLine(to: CGPoint(x: x, y: rect.height - padding))
                        
                        let label = freq >= 1000 ? "\(Int(freq/1000))k" : "\(Int(freq))"
                        let attributes: [NSAttributedString.Key: Any] = [
                                .font: UIFont.systemFont(ofSize: 9),
                                .foregroundColor: UIColor.systemGray
                        ]
                        label.draw(at: CGPoint(x: x - 10, y: rect.height - padding + 2),
                                   withAttributes: attributes)
                }
                
                ctx.strokePath()
        }
        
        private func drawLegend(ctx: CGContext, at origin: CGPoint) {
                let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 10),
                        .foregroundColor: UIColor.white
                ]
                
                var x = origin.x
                for plot in plots {
                        // Color bar
                        ctx.setFillColor(plot.color.cgColor)
                        ctx.fill(CGRect(x: x, y: origin.y + 2, width: 15, height: 2))
                        
                        // Label
                        x += 20
                        plot.name.draw(at: CGPoint(x: x, y: origin.y), withAttributes: attributes)
                        x += plot.name.size(withAttributes: attributes).width + 15
                }
        }
}
