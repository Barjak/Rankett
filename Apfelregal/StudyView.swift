import SwiftUI
import UIKit
import Accelerate

// MARK: - Zoom State
enum ZoomState: Int, CaseIterable {
        case fullSpectrum = 0
        case threeOctaves = 1
        case targetFundamental = 2
        
        var iconName: String {
                switch self {
                case .fullSpectrum: return "magnifyingglass"
                case .threeOctaves: return "magnifyingglass.circle"
                case .targetFundamental: return "magnifyingglass.circle.fill"
                }
        }
}

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
struct StudyView: View {
        @ObservedObject var study: Study
        @ObservedObject var store: TuningParameterStore
        @State private var showingSettings = false
        @State private var zoomState: ZoomState = .fullSpectrum
        
        var body: some View {
                ZStack(alignment: .topTrailing) {
                        StudyGraphViewRepresentable(
                                study: study,
                                store: store,
                                zoomState: $zoomState
                        )
                        .onLongPressGesture(minimumDuration: 0.5) {
                                showingSettings = true
                        }
                        
                        // Zoom button
                        Button(action: cycleZoom) {
                                Image(systemName: zoomState.iconName)
                                        .font(.title2)
                                        .foregroundColor(.white)
                                        .padding(8)
                                        .background(Color.black.opacity(0.6))
                                        .clipShape(Circle())
                        }
                        .padding(.trailing, 12)
                        .padding(.top, 12)
                }
                .sheet(isPresented: $showingSettings) {
                        SettingsModalView(store: store)
                }
        }
        
        private func cycleZoom() {
                let currentIndex = zoomState.rawValue
                let nextIndex = (currentIndex + 1) % ZoomState.allCases.count
                zoomState = ZoomState.allCases[nextIndex]
        }
}

// MARK: - Settings Modal
struct SettingsModalView: View {
        @ObservedObject var store: TuningParameterStore
        @Environment(\.dismiss) private var dismiss
        
        var body: some View {
                NavigationView {
                        Form {
                                Section("Noise Floor Parameters") {
                                        VStack(alignment: .leading) {
                                                Text("Threshold Offset: \(store.noiseThresholdOffset, specifier: "%.1f") dB")
                                                        .font(.caption)
                                                Slider(value: $store.noiseThresholdOffset, in: -5...20)
                                        }
                                        
                                        VStack(alignment: .leading) {
                                                Text("Quantile: \(store.noiseQuantile, specifier: "%.3f")")
                                                        .font(.caption)
                                                LogarithmicSlider(
                                                        value: $store.noiseQuantile,
                                                        range: 0.01...20.0
                                                )
                                        }
                                        
                                        VStack(alignment: .leading) {
                                                Text("Bandwidth: \(store.noiseFloorBandwidthSemitones, specifier: "%.1f") semitones")
                                                        .font(.caption)
                                                Slider(value: $store.noiseFloorBandwidthSemitones, in: 1.0...12.0)
                                        }
                                }
                        }
                        .navigationTitle("Study Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                        Button("Done") { dismiss() }
                                }
                        }
                }
        }
}

// MARK: - Logarithmic Slider
struct LogarithmicSlider: View {
        @Binding var value: Float
        let range: ClosedRange<Float>
        
        @State private var sliderValue: Float = 0
        
        var body: some View {
                Slider(value: $sliderValue, in: 0...1) { _ in
                        value = exponentialValue(from: sliderValue)
                }
                .onAppear {
                        sliderValue = logarithmicValue(from: value)
                }
                .onChange(of: sliderValue) { newValue in
                        value = exponentialValue(from: newValue)
                }
        }
        
        private func logarithmicValue(from value: Float) -> Float {
                let logMin = log10(range.lowerBound)
                let logMax = log10(range.upperBound)
                let logValue = log10(value)
                return (logValue - logMin) / (logMax - logMin)
        }
        
        private func exponentialValue(from sliderValue: Float) -> Float {
                let logMin = log10(range.lowerBound)
                let logMax = log10(range.upperBound)
                let logValue = logMin + sliderValue * (logMax - logMin)
                return pow(10, logValue)
        }
}

// MARK: - UIViewRepresentable Wrapper
struct StudyGraphViewRepresentable: UIViewRepresentable {
        @ObservedObject var study: Study
        @ObservedObject var store: TuningParameterStore
        @Binding var zoomState: ZoomState
        
        func makeUIView(context: Context) -> StudyGraphView {
                let view = StudyGraphView(store: store)
                view.backgroundColor = .black
                view.isOpaque = true
                view.contentMode = .redraw
                return view
        }
        
        func updateUIView(_ uiView: StudyGraphView, context: Context) {
                uiView.zoomState = zoomState
                uiView.updateTargets(
                        originalSpectrum: study.targetOriginalSpectrum,
                        noiseFloor: study.targetNoiseFloor,
                        denoisedSpectrum: study.targetDenoisedSpectrum,
                        frequencies: study.targetFrequencies,
                        hpsSpectrum: study.targetHPSSpectrum,
                        hpsFundamental: study.targetHPSFundamental,
                        musicPeaks: study.musicPeaks,
                        musicSpectrum: study.musicSpectrum,
                        musicGrid: study.musicGrid,
                )
                uiView.setNeedsDisplay()
        }
}
// MARK: - UIKit Graph View (Fixed)
final class StudyGraphView: UIView {
        private let store: TuningParameterStore
        private var displayTimer: Timer?
        var zoomState: ZoomState = .fullSpectrum
        
        // Pre-allocated plots for regular spectra (only 4 now)
        private var plots: [Plot] = [
                Plot(color: .systemBlue.withAlphaComponent(0.5), name: "Original", lineWidth: 0.8),
                Plot(color: .systemRed, name: "Noise Floor", lineWidth: 0.8),
                Plot(color: .systemGreen, name: "Denoised", lineWidth: 0.8),
                Plot(color: .systemPurple, name: "HPS", lineWidth: 0.5)
        ]
        
        // MUSIC data - kept separate at high resolution
        private var musicSpectrum: [Float] = []
        private var targetMusicSpectrum: [Float] = []
        private var musicFrequencies: [Float] = []
        private var musicPeaks: [Float] = []
        private var targetMusicPeaks: [Float] = []
        private let musicColor = UIColor.systemOrange
        private let musicLineWidth: CGFloat = 1.2
        
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
        
        private func updateFrequencyRange() {
                switch zoomState {
                case .fullSpectrum:
                        store.currentMinFreq = store.renderMinFrequency
                        store.currentMaxFreq = store.renderMaxFrequency
                        
                case .threeOctaves:
                        // Three octaves above target pitch, starting at -1 semitone
                        let baseFreq = store.targetNote.transposed(by: -1).frequency(concertA: store.concertPitch)
                        let maxFreq = store.targetNote.transposed(by: 12 * 3).frequency(concertA: store.concertPitch)
                        store.currentMinFreq = Double(baseFreq)
                        store.currentMaxFreq = min(Double(maxFreq), store.renderMaxFrequency)
                        
                case .targetFundamental:
                        // ±50 cents around target pitch
                        let centerFreq = Double(store.targetFrequency())
                        store.currentMinFreq = centerFreq * pow(2, -50.0/1200.0)
                        store.currentMaxFreq = centerFreq * pow(2, 50.0/1200.0)
                }
        }
        
        func updateTargets(originalSpectrum: [Float], noiseFloor: [Float],
                           denoisedSpectrum: [Float], frequencies: [Float],
                           hpsSpectrum: [Float], hpsFundamental: Float,
                           musicPeaks: [Double], musicSpectrum: [Double],
                           musicGrid: [Double]) {
                dataLock.lock()
                defer { dataLock.unlock() }
                
                guard !originalSpectrum.isEmpty else { return }
                
                // Update bin mapper if needed
                if binMapper == nil || binMapper?.binFrequencies.count != store.downscaleBinCount {
                        binMapper = BinMapper(store: store, halfSize: originalSpectrum.count)
                }
                
                guard let mapper = binMapper else { return }
                
                // Map all regular spectra to display bins
                plots[0].target = mapper.mapSpectrum(originalSpectrum)
                plots[1].target = mapper.mapSpectrum(noiseFloor)
                plots[2].target = mapper.mapSpectrum(denoisedSpectrum)
                plots[3].target = mapper.mapHPSSpectrum(hpsSpectrum)
                
                if !musicSpectrum.isEmpty && !musicGrid.isEmpty {
                        // Convert normalized frequencies to Hz
                        let fs = store.audioSampleRate
                        musicFrequencies = musicGrid.map { Float($0 * fs / (2.0 * Double.pi)) }
                        
                        // Use raw MUSIC values directly - they're already power values, not dB!
                        targetMusicSpectrum = musicSpectrum.map { 0.1 * Float($0) }
                        
                        // Initialize current if empty
                        if self.musicSpectrum.isEmpty {
                                self.musicSpectrum = targetMusicSpectrum
                        }
                }
                
                // Store frequencies and peaks
                self.frequencies = mapper.binFrequencies
                self.targetMusicPeaks = musicPeaks.map { Float($0) }
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
                
                // Smooth MUSIC spectrum
                if musicSpectrum.count == targetMusicSpectrum.count && !targetMusicSpectrum.isEmpty {
                        for i in 0..<musicSpectrum.count {
                                musicSpectrum[i] = musicSpectrum[i] * factor + targetMusicSpectrum[i] * (1.0 - factor)
                        }
                } else if !targetMusicSpectrum.isEmpty {
                        musicSpectrum = targetMusicSpectrum
                }
                
                // Smooth special data
                hpsFundamental = hpsFundamental * factor + targetHPSFundamental * (1.0 - factor)
                
                // Smooth MUSIC peaks
                if musicPeaks.count == targetMusicPeaks.count {
                        for i in 0..<musicPeaks.count {
                                musicPeaks[i] = musicPeaks[i] * factor + targetMusicPeaks[i] * (1.0 - factor)
                        }
                } else {
                        musicPeaks = targetMusicPeaks
                }
                
                dataLock.unlock()
                setNeedsDisplay()
        }
        
        override func draw(_ rect: CGRect) {
                guard let ctx = UIGraphicsGetCurrentContext() else { return }
                
                dataLock.lock()
                let plotData = plots.map { ($0.current, $0.color, $0.lineWidth) }
                let freq = frequencies
                let fundamental = hpsFundamental
                let peaks = musicPeaks
                let musicSpec = musicSpectrum
                let musicFreq = musicFrequencies
                dataLock.unlock()
                
                guard !freq.isEmpty else { return }
                
                // Update frequency range once for this draw cycle
                updateFrequencyRange()
                
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
                
                // Draw plots based on zoom state
                if zoomState == .targetFundamental {
                        // In target fundamental mode, show denoised and MUSIC
                        drawSpectrum(ctx: ctx, data: plots[2].current, frequencies: freq,
                                     in: drawRect, color: plots[2].color, lineWidth: plots[2].lineWidth)
                        
                        // Draw MUSIC spectrum at full resolution
                        if !musicSpec.isEmpty && !musicFreq.isEmpty {
                                drawMUSICSpectrum(ctx: ctx, spectrum: musicSpec, frequencies: musicFreq,
                                                  in: drawRect)
                        }
                        
                        // Draw MUSIC frequency estimates
                        let topPeaks = peaks
                                .filter { $0 >= Float(store.currentMinFreq) && $0 <= Float(store.currentMaxFreq) }
                                .prefix(1)
                        
                        for peakFreq in topPeaks {
                                drawMUSICPeak(ctx: ctx, frequency: peakFreq, in: drawRect)
                        }
                } else {
                        // Draw regular plots (0-3)
//                        for i in 0..<4 {
//                                drawSpectrum(ctx: ctx, data: plots[i].current, frequencies: freq,
//                                             in: drawRect, color: plots[i].color, lineWidth: plots[i].lineWidth)
//                        }
                        // Draw MUSIC spectrum at full resolution
                        if !musicSpec.isEmpty && !musicFreq.isEmpty {
                                drawMUSICSpectrum(ctx: ctx, spectrum: musicSpec, frequencies: musicFreq,
                                                  in: drawRect)
                        }
//                        
//                        // Draw MUSIC frequency estimates
//                        for peakFreq in peaks {
//                                if peakFreq >= Float(store.currentMinFreq) && peakFreq <= Float(store.currentMaxFreq) {
//                                        drawMUSICPeak(ctx: ctx, frequency: peakFreq, in: drawRect)
//                                }
//                        }
                }
                
                // Draw HPS fundamental marker
                if fundamental > Float(store.currentMinFreq) && fundamental < Float(store.currentMaxFreq) {
                        drawFundamentalMarker(ctx: ctx, frequency: fundamental,
                                              in: drawRect, color: plots[3].color)
                }
                
                ctx.restoreGState()
                
                // Draw legend
                drawLegend(ctx: ctx, at: CGPoint(x: 10, y: 5))
                
                // Draw zoom indicator
                if zoomState != .fullSpectrum {
                        drawZoomIndicator(ctx: ctx, at: CGPoint(x: rect.width - 150, y: 5))
                }
        }
        
        private func drawMUSICSpectrum(ctx: CGContext, spectrum: [Float], frequencies: [Float],
                                       in rect: CGRect) {
                guard spectrum.count == frequencies.count else { return }
                
                ctx.setStrokeColor(musicColor.cgColor)
                ctx.setLineWidth(musicLineWidth)
                
                let path = CGMutablePath()
                var started = false
                
                // Convert spectrum to dB scale
                // MUSIC pseudospectrum is a power measure, so use 10*log10
                // Add a small epsilon to avoid log(0)
                let epsilon: Float = 1e-10
                let spectrumDB = spectrum.map { 10.0 * log10(max($0, epsilon)) }
                
                // Find the actual min/max in the dB spectrum for better scaling
                let actualMinDB = spectrumDB.min() ?? -60.0
                let actualMaxDB = spectrumDB.max() ?? 0.0
                
                // You can either use the actual range or fixed bounds
                // Option 1: Use actual range with some padding
                let dbPadding: Float = 10.0
                let displayMinDB = actualMinDB - dbPadding
                let displayMaxDB = actualMaxDB + dbPadding
                
                // Option 2: Use fixed bounds (uncomment if preferred)
                // let displayMinDB: Float = -60.0  // or use self.minDB if it's a property
                // let displayMaxDB: Float = 60.0   // or use self.maxDB if it's a property
                
                for (i, freq) in frequencies.enumerated() {
                        // MUSIC frequencies are only valid in the specified range
                        guard freq >= Float(store.currentMinFreq), freq <= Float(store.currentMaxFreq) else { continue }
                        
                        let x = mapFrequencyToX(freq, in: rect)
                        
                        // Normalize the dB value to [0, 1] range for display
                        let dbValue = spectrumDB[i]
                        let normalizedValue = (dbValue - displayMinDB) / (displayMaxDB - displayMinDB)
                        
                        // Clamp to [0, 1] to handle any outliers
                        let clampedValue = max(0.0, min(1.0, normalizedValue))
                        
                        // Map to y-coordinate (invert since y=0 is at top)
                        let y = rect.height * (1.0 - CGFloat(clampedValue))
                        
                        if started {
                                path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                                path.move(to: CGPoint(x: x, y: y))
                                started = true
                        }
                }
                
                ctx.addPath(path)
                ctx.strokePath()
                
                // Optional: Draw dB scale labels
                drawDBScaleLabels(ctx: ctx, rect: rect, minDB: displayMinDB, maxDB: displayMaxDB)
        }
        
        // Optional helper function to draw dB scale labels
        private func drawDBScaleLabels(ctx: CGContext, rect: CGRect, minDB: Float, maxDB: Float) {
                let labelFont = UIFont.systemFont(ofSize: 10)
                let attributes: [NSAttributedString.Key: Any] = [
                        .font: labelFont,
                        .foregroundColor: UIColor.gray
                ]
                
                // Draw a few dB reference lines and labels
                let dbSteps: [Float] = [-60, -40, -20, 0, 20, 40, 60].filter { $0 >= minDB && $0 <= maxDB }
                
                for db in dbSteps {
                        let normalizedValue = (db - minDB) / (maxDB - minDB)
                        let y = rect.height * (1.0 - CGFloat(normalizedValue))
                        
                        // Draw horizontal grid line
                        ctx.setStrokeColor(UIColor.gray.withAlphaComponent(0.2).cgColor)
                        ctx.setLineWidth(0.5)
                        ctx.move(to: CGPoint(x: rect.minX, y: y))
                        ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                        ctx.strokePath()
                        
                        // Draw label
                        let label = "\(Int(db)) dB"
                        let size = label.size(withAttributes: attributes)
                        let labelRect = CGRect(x: rect.minX - size.width - 5,
                                               y: y - size.height/2,
                                               width: size.width,
                                               height: size.height)
                        label.draw(in: labelRect, withAttributes: attributes)
                }
        }
        
        private func drawMUSICPeak(ctx: CGContext, frequency: Float, in rect: CGRect) {
                let x = mapFrequencyToX(frequency, in: rect)
                
                // Draw vertical line with distinct style
                ctx.setStrokeColor(musicColor.cgColor)
                ctx.setLineWidth(2.0)
                ctx.setLineDash(phase: 0, lengths: [4, 2])
                
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: rect.height))
                ctx.strokePath()
                
                // Reset line dash
                ctx.setLineDash(phase: 0, lengths: [])
                
                // Draw frequency label
                let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.boldSystemFont(ofSize: 10),
                        .foregroundColor: musicColor,
                        .backgroundColor: UIColor.black.withAlphaComponent(0.7)
                ]
                
                let label = String(format: "%.3f Hz", frequency)
                let labelSize = label.size(withAttributes: attributes)
                
                // Position label to avoid overlap
                var labelY = CGFloat(10)
                if x > rect.width / 2 {
                        label.draw(at: CGPoint(x: x - labelSize.width - 5, y: labelY), withAttributes: attributes)
                } else {
                        label.draw(at: CGPoint(x: x + 5, y: labelY), withAttributes: attributes)
                }
        }
        
        private func mapFrequencyToX(_ freq: Float, in rect: CGRect) -> CGFloat {
                if store.renderWithLogFrequencyScale {
                        let logMin = log10(store.currentMinFreq)
                        let logMax = log10(store.currentMaxFreq)
                        let logFreq = log10(freq)
                        return CGFloat((Double(logFreq) - logMin) / (logMax - logMin)) * rect.width
                } else {
                        let normalized = (Double(freq) - store.currentMinFreq) / (store.currentMaxFreq - store.currentMinFreq)
                        return CGFloat(normalized) * rect.width
                }
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
                        guard freq >= Float(store.currentMinFreq), freq <= Float(store.currentMaxFreq) else { continue }
                        
                        let x = mapFrequencyToX(freq, in: rect)
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
                let x = mapFrequencyToX(frequency, in: rect)
                
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

                
                // Frequency lines - automatically calculated
                let freqLines = calculateFrequencyGridLines()
                
                for (freq, label) in freqLines {
                        guard freq >= Float(store.currentMinFreq), freq <= Float(store.currentMaxFreq) else { continue }
                        
                        let x = mapFrequencyToX(freq, in: CGRect(x: 0, y: 0,
                                                                 width: rect.width - padding,
                                                                 height: rect.height))
                        
                        ctx.move(to: CGPoint(x: x, y: padding))
                        ctx.addLine(to: CGPoint(x: x, y: rect.height - padding))
                        
                        let attributes: [NSAttributedString.Key: Any] = [
                                .font: UIFont.systemFont(ofSize: 9),
                                .foregroundColor: UIColor.systemGray
                        ]
                        label.draw(at: CGPoint(x: x - 10, y: rect.height - padding + 2),
                                   withAttributes: attributes)
                }
                
                ctx.strokePath()
        }
        
        private func calculateFrequencyGridLines() -> [(freq: Float, label: String)] {
                let range = store.currentMaxFreq - store.currentMinFreq
                let logRange = log10(store.currentMaxFreq / store.currentMinFreq)
                
                var lines: [(Float, String)] = []
                
                if logRange < 0.5 {
                        // Very narrow range - use linear spacing
                        let step = calculateNiceStep(Float(range), targetCount: 5)
                        var freq = ceil(Float(store.currentMinFreq) / step) * step
                        
                        while freq <= Float(store.currentMaxFreq)
                        {
                                if zoomState == .targetFundamental {
                                        // Show as cents relative to target
                                        let target = Float(store.targetNote.frequency(concertA: store.concertPitch))
                                        let cents = 1200 * log2(freq / target)
                                        lines.append((freq, String(format: "%+.0fc", cents)))
                                } else {
                                        lines.append((freq, formatFrequency(freq)))
                                }
                                freq += step
                        }
                } else {
                        // Wide range - use logarithmic spacing
                        let decades = [1, 2, 5]
                        var magnitude = pow(10, floor(log10(Double(store.currentMinFreq))))
                        
                        while magnitude <= Double(store.currentMaxFreq) * 10 {
                                for factor in decades {
                                        let freq = Float(magnitude * Double(factor))
                                        if freq >= Float(store.currentMinFreq) && freq <= Float(store.currentMaxFreq) {
                                                lines.append((freq, formatFrequency(freq)))
                                        }
                                }
                                magnitude *= 10
                        }
                }
                
                return lines
        }
        
        private func calculateNiceStep(_ range: Float, targetCount: Int) -> Float {
                let roughStep = range / Float(targetCount)
                let magnitude = pow(10, floor(log10(Double(roughStep))))
                let normalized = Double(roughStep) / magnitude
                
                let niceValue: Double
                if normalized <= 1 {
                        niceValue = 1
                } else if normalized <= 2 {
                        niceValue = 2
                } else if normalized <= 5 {
                        niceValue = 5
                } else {
                        niceValue = 10
                }
                
                return Float(niceValue * magnitude)
        }
        
        private func formatFrequency(_ freq: Float) -> String {
                if freq >= 1000 {
                        return String(format: "%.3gk", freq / 1000)
                } else if freq >= 100 {
                        return String(format: "%.0f", freq)
                } else {
                        return String(format: "%.1f", freq)
                }
        }
        
        private func drawLegend(ctx: CGContext, at origin: CGPoint) {
                let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 10),
                        .foregroundColor: UIColor.white
                ]
                
                var x = origin.x
                var legendItems: [(color: UIColor, name: String)] = []
                
                switch zoomState {
                case .fullSpectrum, .threeOctaves:
                        legendItems = plots.map { ($0.color, $0.name) }
                case .targetFundamental:
                        legendItems = [
                                (plots[2].color, plots[2].name), // Denoised
                                (musicColor, "MUSIC")  // MUSIC
                        ]
                }
                
                for (color, name) in legendItems {
                        // Color bar
                        ctx.setFillColor(color.cgColor)
                        ctx.fill(CGRect(x: x, y: origin.y + 2, width: 15, height: 2))
                        
                        // Label
                        x += 20
                        name.draw(at: CGPoint(x: x, y: origin.y), withAttributes: attributes)
                        x += name.size(withAttributes: attributes).width + 15
                }
        }
        
        private func drawZoomIndicator(ctx: CGContext, at origin: CGPoint) {
                let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 10),
                        .foregroundColor: UIColor.systemOrange
                ]
                
                let text: String
                switch zoomState {
                case .fullSpectrum:
                        text = "Full Spectrum"
                case .threeOctaves:
                        text = "3 Octaves"
                case .targetFundamental:
                        text = "±50 cents"
                }
                
                text.draw(at: origin, withAttributes: attributes)
        }
}
