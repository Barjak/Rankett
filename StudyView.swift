import SwiftUI
import UIKit

struct StudyView: UIViewRepresentable {
        @ObservedObject var study: Study
        
        func makeUIView(context: Context) -> StudyGraphView {
                let view = StudyGraphView()
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
        }
}

// StudyGraphView remains the same

final class StudyGraphView: UIView {
        private let config = AnalyzerConfig.default
        private var displayTimer: Timer?
        
        // Current (smoothed) display data
        private var currentOriginal: [Float] = []
        private var currentNoiseFloor: [Float] = []
        private var currentDenoised: [Float] = []
        private var currentFrequencies: [Float] = []
        private var currentPeaks: [Peak] = []
        private var smoothedPeakPositions: [Float: CGPoint] = [:] // Track by frequency

        
        // Target data (from Study)
        private var targetOriginal: [Float] = []
        private var targetNoiseFloor: [Float] = []
        private var targetDenoised: [Float] = []
        private var targetFrequencies: [Float] = []
        private var targetPeaks: [Peak] = []
        
        
        private var currentHPSSpectrum: [Float] = []
        private var targetHPSSpectrum: [Float] = []
        private var currentHPSFundamental: Float = 0
        private var targetHPSFundamental: Float = 0
        
        // Bin mapper
        private var binMapper: BinMapper?
        
        // Thread safety
        private let dataLock = NSLock()
        
        override init(frame: CGRect) {
                super.init(frame: frame)
                setupTimer()
        }
        
        required init?(coder: NSCoder) {
                super.init(coder: coder)
                setupTimer()
        }
        
        deinit {
                displayTimer?.invalidate()
        }
        
        private func setupTimer() {
                displayTimer = Timer.scheduledTimer(withTimeInterval: config.rendering.frameInterval, repeats: true) { [weak self] _ in
                        self?.updateDisplay()
                }
        }
        
        func updateTargets(originalSpectrum: [Float], noiseFloor: [Float], denoisedSpectrum: [Float],
                           frequencies: [Float],
                           hpsSpectrum: [Float], hpsFundamental: Float) {
                dataLock.lock()
                defer { dataLock.unlock() }
                
                guard !originalSpectrum.isEmpty else { return }
                
                // Create bin mapper if needed
                if binMapper == nil || binMapper?.binFrequencies.count != config.fft.outputBinCount {
                        binMapper = BinMapper(config: config, halfSize: originalSpectrum.count)
                }
                
                // Map full resolution data to display bins
                if let mapper = binMapper {
                        targetOriginal = mapper.mapSpectrum(originalSpectrum)
                        targetNoiseFloor = mapper.mapSpectrum(noiseFloor)
                        targetDenoised = mapper.mapSpectrum(denoisedSpectrum)
                        targetFrequencies = mapper.binFrequencies
                        
                        // Bin-map HPS spectrum too
                        // Note: HPS spectrum is shorter, so we need to handle it specially
                        targetHPSSpectrum = mapper.mapHPSSpectrum(hpsSpectrum)
                }
                
                targetHPSFundamental = hpsFundamental
                
                // Initialize current data if empty
                if currentOriginal.isEmpty {
                        currentOriginal = targetOriginal
                        currentNoiseFloor = targetNoiseFloor
                        currentDenoised = targetDenoised
                        currentFrequencies = targetFrequencies
                        currentHPSSpectrum = targetHPSSpectrum
                        currentHPSFundamental = targetHPSFundamental
                }
        }
        
        private func updateDisplay() {
                dataLock.lock()
                
                // Smooth interpolation
                let alpha = config.rendering.smoothingFactor
                let beta = 1.0 - alpha
                
                // Smooth spectrum data
                if targetOriginal.count == currentOriginal.count {
                        for i in 0..<currentOriginal.count {
                                currentOriginal[i] = currentOriginal[i] * alpha + targetOriginal[i] * beta
                                currentNoiseFloor[i] = currentNoiseFloor[i] * alpha + targetNoiseFloor[i] * beta
                                currentDenoised[i] = currentDenoised[i] * alpha + targetDenoised[i] * beta
                        }
                }
                
                currentFrequencies = targetFrequencies
                
                if targetHPSSpectrum.count == currentHPSSpectrum.count {
                        for i in 0..<currentHPSSpectrum.count {
                                currentHPSSpectrum[i] = currentHPSSpectrum[i] * alpha + targetHPSSpectrum[i] * beta
                        }
                }
                currentHPSFundamental = currentHPSFundamental * alpha + targetHPSFundamental * beta
                
                dataLock.unlock()
                setNeedsDisplay()
        }
        // In StudyGraphView, update the draw method:
        override func draw(_ rect: CGRect) {
                guard let ctx = UIGraphicsGetCurrentContext() else { return }
                
                dataLock.lock()
                let originalDB = currentOriginal
                let noiseFloorDB = currentNoiseFloor
                let denoisedDB = currentDenoised
                let frequencies = currentFrequencies
                let hpsSpectrum = currentHPSSpectrum
                dataLock.unlock()
                
                guard !originalDB.isEmpty else { return }
                
                let verticalPadding: CGFloat = 40
                let rightMargin: CGFloat = 40 // Space for SNR scale
                let width = rect.width - rightMargin
                let height = rect.height - 2 * verticalPadding
                
                // Draw background
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(rect)
                
                // Fixed dB range
                let minDB: Float = -80
                let maxDB: Float = 180
                let dbRange = maxDB - minDB
                
                // Draw grid
                drawGrid(ctx: ctx, rect: rect, verticalPadding: verticalPadding,
                         rightMargin: rightMargin, minDB: minDB, maxDB: maxDB)
                
                ctx.saveGState()
                ctx.translateBy(x: 0, y: verticalPadding)
                
                // Draw curves
                drawSpectrumCurve(ctx: ctx, data: originalDB, frequencies: frequencies,
                                  width: width, height: height,
                                  minDB: minDB, dbRange: dbRange,
                                  color: UIColor.systemBlue.withAlphaComponent(0.5))
                
                drawSpectrumCurve(ctx: ctx, data: noiseFloorDB, frequencies: frequencies,
                                  width: width, height: height,
                                  minDB: minDB, dbRange: dbRange, color: UIColor.systemRed)
                
                drawDenoisedSpectrum(ctx: ctx, denoisedDB: denoisedDB, frequencies: frequencies,
                                     width: width, height: height,
                                     minDB: minDB, dbRange: dbRange, color: UIColor.systemGreen)
                
                // After drawing other curves, add HPS
                drawHPSSpectrum(ctx: ctx, hpsSpectrum: hpsSpectrum, frequencies: frequencies,
                                width: width, height: height, minDB: minDB, dbRange: dbRange)
                
                // Draw fundamental frequency indicator
                drawFundamental(ctx: ctx, fundamental: currentHPSFundamental,
                                width: width, height: height)
                
                ctx.restoreGState()
                
                // Draw SNR scale on right side
                drawSNRScale(ctx: ctx, rect: rect, verticalPadding: verticalPadding,
                             rightMargin: rightMargin, height: height)
                
                // Draw legend
                drawLegend(ctx: ctx, rect: rect, verticalPadding: verticalPadding)
        }
        
        
        // Add HPS drawing method:
        private func drawHPSSpectrum(ctx: CGContext, hpsSpectrum: [Float], frequencies: [Float],
                                     width: CGFloat, height: CGFloat,
                                     minDB: Float, dbRange: Float) {
                guard !hpsSpectrum.isEmpty else { return }
                
                ctx.setStrokeColor(UIColor.systemPurple.cgColor)
                ctx.setLineWidth(1.5)
                
                let path = CGMutablePath()
                var firstPoint = true
                
                // Now HPS spectrum is already bin-mapped and aligned with frequencies array
                for (i, value) in hpsSpectrum.enumerated() {
                        guard i < frequencies.count else { break }
                        
                        let freq = frequencies[i]
                        
                        // Skip if outside display range
                        guard freq >= 20 && freq <= 20000 else { continue }
                        
                        // Use log scale for x position
                        let logMin = log10(20.0)
                        let logMax = log10(20000.0)
                        let logFreq = log10(Double(freq))
                        let normalizedX = CGFloat((logFreq - logMin) / (logMax - logMin))
                        let x = normalizedX * width
                        
                        // Map value to y position
                        let clampedValue = max(minDB, min(minDB + dbRange, value))
                        let normalizedValue = (clampedValue - minDB) / dbRange
                        let y = height * (1 - CGFloat(normalizedValue))
                        
                        if firstPoint {
                                path.move(to: CGPoint(x: x, y: y))
                                firstPoint = false
                        } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                        }
                }
                
                if !firstPoint {
                        ctx.addPath(path)
                        ctx.strokePath()
                }
        }
        
        // Add fundamental frequency indicator:
        private func drawFundamental(ctx: CGContext, fundamental: Float,
                                     width: CGFloat, height: CGFloat) {
                guard fundamental > 20 && fundamental < 20000 else { return }
                
                // Calculate x position for fundamental
                let logMin = log10(20.0)
                let logMax = log10(20000.0)
                let logFreq = log10(Double(fundamental))
                let normalizedX = CGFloat((logFreq - logMin) / (logMax - logMin))
                let x = normalizedX * width
                
                // Draw vertical line at fundamental
                ctx.setStrokeColor(UIColor.systemPurple.cgColor)
                ctx.setLineWidth(2)
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: height))
                ctx.strokePath()
                
                // Draw label
                let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.boldSystemFont(ofSize: 11),
                        .foregroundColor: UIColor.systemPurple
                ]
                let text = String(format: "F₀: %.0f Hz", fundamental)
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: x + 5, y: 5), withAttributes: attributes)
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
        
        
        private func drawLegend(ctx: CGContext, rect: CGRect, verticalPadding: CGFloat) {
                let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 10),
                        .foregroundColor: UIColor.white
                ]
                
                let legendItems = [
                        ("Original", UIColor.systemBlue.withAlphaComponent(0.5)),
                        ("Noise Floor", UIColor.systemRed),
                        ("Denoised", UIColor.systemGreen),
                        ("HPS", UIColor.systemPurple)
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
        

        
        // Add this new method to draw SNR scale:
        private func drawSNRScale(ctx: CGContext, rect: CGRect, verticalPadding: CGFloat,
                                  rightMargin: CGFloat, height: CGFloat) {
                ctx.saveGState()
                
                let x = rect.width - rightMargin + 10
                let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 9),
                        .foregroundColor: UIColor.systemGreen
                ]
                
                // Draw title
                let title = "SNR (dB)"
                let titleSize = title.size(withAttributes: attributes)
                title.draw(at: CGPoint(x: x + 5, y: verticalPadding - 20), withAttributes: attributes)
                
                // Draw scale markers
                let snrValues: [Float] = [0, 20, 40, 60, 80]
                for snr in snrValues {
                        // Map SNR to denoised spectrum display position
                        let normalizedSNR = snr / 80.0 // Assuming max SNR display of 80 dB
                        let y = verticalPadding + height * CGFloat(1 - normalizedSNR)
                        
                        // Draw tick
                        ctx.setStrokeColor(UIColor.systemGreen.withAlphaComponent(0.5).cgColor)
                        ctx.setLineWidth(0.5)
                        ctx.move(to: CGPoint(x: x, y: y))
                        ctx.addLine(to: CGPoint(x: x + 5, y: y))
                        ctx.strokePath()
                        
                        // Draw label
                        "\(Int(snr))".draw(at: CGPoint(x: x + 8, y: y - 5), withAttributes: attributes)
                }
                
                ctx.restoreGState()
        }
        
        // Update drawDenoisedSpectrum to handle the new scale:
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
                
                for (i, snr) in denoisedDB.enumerated() {
                        // Only draw where signal is above noise floor
                        if snr > 0 {
                                let x = CGFloat(i) * width / CGFloat(denoisedDB.count - 1)
                                
                                // Map SNR to display height (0-80 dB range)
                                let normalizedSNR = min(snr / 80.0, 1.0)
                                let y = height * (1 - CGFloat(normalizedSNR))
                                
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
        
        // Update drawGrid to handle rightMargin:
        private func drawGrid(ctx: CGContext, rect: CGRect, verticalPadding: CGFloat,
                              rightMargin: CGFloat, minDB: Float, maxDB: Float) {
                ctx.saveGState()
                
                let width = rect.width - rightMargin
                let height = rect.height - 2 * verticalPadding
                
                ctx.setStrokeColor(UIColor.systemGray.withAlphaComponent(0.2).cgColor)
                ctx.setLineWidth(0.5)
                
                // Draw horizontal lines (dB scale)
                let dbRange = maxDB - minDB
                let dbStep: Float = 20
                
                var db = minDB
                while db <= maxDB {
                        let y = verticalPadding + height * CGFloat(1 - (db - minDB) / dbRange)
                        ctx.move(to: CGPoint(x: 0, y: y))
                        ctx.addLine(to: CGPoint(x: width, y: y))
                        
                        // Draw label
                        let attributes: [NSAttributedString.Key: Any] = [
                                .font: UIFont.systemFont(ofSize: 9),
                                .foregroundColor: UIColor.systemGray
                        ]
                        "\(Int(db)) dB".draw(at: CGPoint(x: 2, y: y - 5), withAttributes: attributes)
                        
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
                        label.draw(at: CGPoint(x: x - textSize.width/2, y: rect.height - verticalPadding + 2),
                                   withAttributes: attributes)
                }
                
                ctx.strokePath()
                ctx.restoreGState()
        }
}
