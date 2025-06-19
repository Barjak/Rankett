import SwiftUI
import Accelerate

struct ANFBar: Identifiable {
        let id: String
        let frequency: Float
        let amplitude: Float
        let bandwidth: Float
        let convergenceRating: Float
        
        var color: Color {
                // Color based on convergence rating: red (weak) -> yellow -> green (strong)
                let hue = Double(convergenceRating) * 0.33 // 0 to 0.33 (red to green)
                return Color(hue: hue, saturation: 0.8, brightness: 0.9)
        }
}

// MARK: - ANF Visualization State
class ANFVisualizationState: ObservableObject {
        @Published var smoothedBars: [ANFBar] = []
        @Published var smoothingFactor: Double = 0.85
        @Published var originalSpectrum: Plot?
        
        private var barHistory: [String: (frequency: Float, amplitude: Float, bandwidth: Float)] = [:]
        
        init() {
                // Initialize original spectrum plot
                self.originalSpectrum = Plot(
                        color: UIColor.systemBlue.withAlphaComponent(0.5),
                        name: "Original",
                        lineWidth: 0.8
                )
        }
        
        func update(from anfData: [ANFDatum]) {
                print("\n🎯 ANFVisualizationState.update: Processing \(anfData.count) data points")
                
                var newBars: [ANFBar] = []
                
                for (i, datum) in anfData.enumerated() {
                        print("  Data[\(i)]: freq=\(datum.freq), amp=\(datum.amp)")
                        let id = "anf-\(i)"
                        
                        // Get smoothed values
                        let (smoothedFreq, smoothedAmp, smoothedBandwidth) = smoothValues(
                                id: id,
                                frequency: Float(datum.freq),
                                amplitude: Float(datum.amp),
                                bandwidth: Float(datum.bandwidth)
                        )
                        
                        let bar = ANFBar(
                                id: id,
                                frequency: smoothedFreq,
                                amplitude: smoothedAmp,
                                bandwidth: smoothedBandwidth,
                                convergenceRating: Float(datum.convergenceRating)
                        )
                        
                        newBars.append(bar)
                }
                
                // Sort by frequency for stable rendering
                self.smoothedBars = newBars.sorted { $0.frequency < $1.frequency }
                print("  Created \(self.smoothedBars.count) bars")
        }
        
        func updateSpectrum(amplitudes: [Float], frequencies: [Float]) {
                guard var spectrum = self.originalSpectrum,
                      amplitudes.count == frequencies.count,
                      !amplitudes.isEmpty else { return }
                
                
                // Store the new target data
                spectrum.target = amplitudes
                spectrum.frequencies = frequencies
                
                // Initialize current if empty
                if spectrum.current.isEmpty {
                        spectrum.current = spectrum.target
                }
                
                // Apply smoothing
                spectrum.smooth(Float(self.smoothingFactor))
                
                // Update the published property
                self.originalSpectrum = spectrum
        }
        
        private func smoothValues(id: String, frequency: Float, amplitude: Float, bandwidth: Float) -> (Float, Float, Float) {
                let alpha = Float(self.smoothingFactor)
                
                if let history = self.barHistory[id] {
                        // Apply exponential smoothing
                        let smoothedFreq = alpha * history.frequency + (1 - alpha) * frequency
                        let smoothedAmp = alpha * history.amplitude + (1 - alpha) * amplitude
                        let smoothedBandwidth = alpha * history.bandwidth + (1 - alpha) * bandwidth
                        
                        self.barHistory[id] = (smoothedFreq, smoothedAmp, smoothedBandwidth)
                        return (smoothedFreq, smoothedAmp, smoothedBandwidth)
                } else {
                        // First time seeing this bar
                        self.barHistory[id] = (frequency, amplitude, bandwidth)
                        return (frequency, amplitude, bandwidth)
                }
        }
        
        func clearHistory() {
                self.barHistory.removeAll()
        }
}

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

// MARK: - Updated Graph View
struct GraphView: View {
        @ObservedObject var study: Study
        @ObservedObject var store: TuningParameterStore
        @StateObject private var anfState = ANFVisualizationState()
        @State private var zoomState: ZoomState = .fullSpectrum
        
        var frequencyRange: ClosedRange<Double> {
                self.store.currentMinFreq...self.store.currentMaxFreq
        }
        
        var body: some View {
                GeometryReader { geometry in
                        ZStack {
                                // Background
                                Rectangle()
                                        .fill(Color.black.opacity(0.9))
                                
                                // Main plot
                                plotView(size: geometry.size)
                                
                                // Single zoom button in top-right corner
                                VStack {
                                        HStack {
                                                Spacer()
                                                Button(action: cycleZoom) {
                                                        Image(systemName: self.zoomState.iconName)
                                                                .font(.title2)
                                                                .foregroundColor(.white)
                                                                .padding(8)
                                                                .background(Color.black.opacity(0.6))
                                                                .clipShape(Circle())
                                                }
                                                .padding(.trailing, 12)
                                                .padding(.top, 12)
                                        }
                                        Spacer()
                                }
                        }
                        .onAppear {
                                self.study.start()
                                startUpdating()
                        }
                        .onChange(of: self.store.targetNote) { _ in
                                updateZoomBounds()
                        }
                        .onChange(of: self.store.concertPitch) { _ in
                                updateZoomBounds()
                        }
                        .onChange(of: self.store.targetPartial) { _ in
                                updateZoomBounds()
                        }
                }
        }
        
        private func updateZoomBounds() {
                // Only update if we're in a zoom state that depends on target frequency
                if self.zoomState != .fullSpectrum {
                        setZoomState(self.zoomState)
                }
        }
        
        private func cycleZoom() {
                let currentIndex = self.zoomState.rawValue
                let nextIndex = (currentIndex + 1) % ZoomState.allCases.count
                self.zoomState = ZoomState.allCases[nextIndex]
                setZoomState(self.zoomState)
        }
        
        private func plotView(size: CGSize) -> some View {
                Canvas { context, canvasSize in
                        drawGrid(context: context, size: canvasSize)
                        
                        drawOriginalSpectrum(context: context, size: canvasSize)
                        
                        drawANFBars(context: context, size: canvasSize)
                        
                        drawAxes(context: context, size: canvasSize)
                }
        }
        
        private func drawOriginalSpectrum(context: GraphicsContext, size: CGSize) {
                guard let spectrum = self.anfState.originalSpectrum,
                      !spectrum.current.isEmpty,
                      spectrum.current.count == spectrum.frequencies.count else { return }
                
                let freqRange = self.frequencyRange
                let minDB: Float = Float(self.store.currentMinDB)
                let maxDB: Float = Float(self.store.currentMaxDB)
                
                var path = Path()
                var started = false
                
                // Find the indices for one point before and after the visible range
                var startIndex = 0
                var endIndex = spectrum.frequencies.count - 1
                
                // Find the last point before the range
                for i in 0..<spectrum.frequencies.count {
                        if Double(spectrum.frequencies[i]) >= freqRange.lowerBound {
                                startIndex = max(0, i - 1)
                                break
                        }
                }
                
                // Find the first point after the range
                for i in (0..<spectrum.frequencies.count).reversed() {
                        if Double(spectrum.frequencies[i]) <= freqRange.upperBound {
                                endIndex = min(spectrum.frequencies.count - 1, i + 1)
                                break
                        }
                }
                
                // Draw points from startIndex to endIndex
                for i in startIndex...endIndex {
                        let freq = spectrum.frequencies[i]
                        let amplitude = spectrum.current[i]
                        
                        // Calculate x position
                        let x = frequencyToX(Double(freq), size: size.width)
                        
                        // Calculate y position (amplitude in dB)
                        let normalizedValue = (amplitude - minDB) / (maxDB - minDB)
                        let y = size.height * (1 - CGFloat(normalizedValue))
                        
                        if started {
                                path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                                path.move(to: CGPoint(x: x, y: y))
                                started = true
                        }
                }
                
                // Draw the spectrum line
                context.stroke(
                        path,
                        with: .color(Color(spectrum.color)),
                        lineWidth: CGFloat(spectrum.lineWidth)
                )
        }
        
        private func drawANFBars(context: GraphicsContext, size: CGSize) {
                print("\n🎨 Drawing ANF bars:")
                print("  Count: \(self.anfState.smoothedBars.count)")
                print("  Render range: \(self.frequencyRange)")
                
                let barWidth: CGFloat = 2
                let fixedHeight: CGFloat = size.height * 0.5  // 50% of view height
                
                for (index, bar) in self.anfState.smoothedBars.enumerated() {
                        print("  Bar[\(index)]: freq=\(bar.frequency) Hz")
                        
                        let x = frequencyToX(Double(bar.frequency), size: size.width)
                        print("    x position: \(x) (width: \(size.width))")
                        
                        // Fixed height bar for debugging
                        let rect = CGRect(
                                x: x - barWidth/2,
                                y: size.height - fixedHeight,
                                width: barWidth,
                                height: fixedHeight
                        )
                        
                        context.fill(Path(rect), with: .color(bar.color))
                }
        }
        
        private func drawGrid(context: GraphicsContext, size: CGSize) {
                let freqRange = self.frequencyRange
                
                // Frequency grid lines (logarithmic)
                let gridFrequencies = logarithmicGridLines(
                        min: freqRange.lowerBound,
                        max: freqRange.upperBound
                )
                
                for freq in gridFrequencies {
                        let x = frequencyToX(freq, size: size.width)
                        
                        context.stroke(
                                Path { path in
                                        path.move(to: CGPoint(x: x, y: 0))
                                        path.addLine(to: CGPoint(x: x, y: size.height))
                                },
                                with: .color(.gray.opacity(0.3)),
                                lineWidth: 1
                        )
                }
                
                // Amplitude grid lines (linear)
                let dbLines = stride(from: self.store.currentMinDB, through: 0, by: 10)
                
                for db in dbLines {
                        let y = size.height - (CGFloat(db - self.store.currentMinDB) / CGFloat(self.store.currentMaxDB - self.store.currentMinDB)) * size.height * 0.8
                        
                        context.stroke(
                                Path { path in
                                        path.move(to: CGPoint(x: 0, y: y))
                                        path.addLine(to: CGPoint(x: size.width, y: y))
                                },
                                with: .color(.gray.opacity(0.3)),
                                lineWidth: 1
                        )
                        
                        // Draw dB label
                        let text = Text("\(Int(db))dB")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        
                        context.draw(text, at: CGPoint(x: 10, y: y - 5))
                }
        }
        
        private func drawAxes(context: GraphicsContext, size: CGSize) {
                // X-axis
                context.stroke(
                        Path { path in
                                path.move(to: CGPoint(x: 0, y: size.height))
                                path.addLine(to: CGPoint(x: size.width, y: size.height))
                        },
                        with: .color(.white),
                        lineWidth: 2
                )
                
                // Y-axis
                context.stroke(
                        Path { path in
                                path.move(to: CGPoint(x: 0, y: 0))
                                path.addLine(to: CGPoint(x: 0, y: size.height))
                        },
                        with: .color(.white),
                        lineWidth: 2
                )
        }
        
        private func frequencyToX(_ freq: Double, size: CGFloat) -> CGFloat {
                let freqRange = self.frequencyRange
                let logMinFreq = log10(freqRange.lowerBound)
                let logMaxFreq = log10(freqRange.upperBound)
                let logRange = logMaxFreq - logMinFreq
                let logFreq = log10(freq)
                let normalized = (logFreq - logMinFreq) / logRange
                return CGFloat(normalized) * size
        }
        
        private func logarithmicGridLines(min: Double, max: Double) -> [Double] {
                var lines: [Double] = []
                let logMin = log10(min)
                let logMax = log10(max)
                let decades = Int(logMax) - Int(logMin) + 1
                
                for decade in 0...decades {
                        let base = pow(10, Double(Int(logMin) + decade))
                        for mult in [1.0, 2.0, 5.0] {
                                let freq = base * mult
                                if freq >= min && freq <= max {
                                        lines.append(freq)
                                }
                        }
                }
                
                return lines
        }
        
        // MARK: - Zoom Functions
        
        private func setZoomState(_ state: ZoomState) {
                switch state {
                case .fullSpectrum:
                        self.store.currentMinFreq = self.store.renderMinFrequency
                        self.store.currentMaxFreq = self.store.renderMaxFrequency
                        
                case .threeOctaves:
                        // Three octaves above target pitch, starting at -1 semitone
                        let baseFreq = self.store.targetNote.transposed(by: -1).frequency(concertA: self.store.concertPitch)
                        let maxFreq = self.store.targetNote.transposed(by: 12 * 3).frequency(concertA: self.store.concertPitch)
                        self.store.currentMinFreq = Double(baseFreq)
                        self.store.currentMaxFreq = min(Double(maxFreq), self.store.renderMaxFrequency)
                        
                case .targetFundamental:
                        // ±50 cents around target pitch
                        let centerFreq = Double(self.store.targetFrequency())
                        self.store.currentMinFreq = centerFreq * pow(2, -50.0/1200.0)
                        self.store.currentMaxFreq = centerFreq * pow(2, 50.0/1200.0)
                }
        }
        
        // MARK: - Updates
        
        private func startUpdating() {
                Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { _ in
                        // Update ANF bars
                        // Debug: Check what Study ha
                        
                        self.anfState.update(from: self.study.currentANFData)
                        
                        if !self.study.targetOriginalSpectrum.isEmpty {
                                print("🎨 Updating spectrum with \(self.study.targetOriginalSpectrum.count) points")
                        }
                        
                        // Update spectrum if available
                        if let binMapper = self.study.binMapper,
                           !self.study.targetOriginalSpectrum.isEmpty,
                           self.study.targetOriginalSpectrum.count == self.study.targetFrequencies.count {
                                
                                // Map the full spectrum to display bins
                                let mappedSpectrum = binMapper.mapSpectrum(self.study.targetOriginalSpectrum)
                                
                                // Update the visualization state with mapped spectrum
                                self.anfState.updateSpectrum(
                                        amplitudes: mappedSpectrum,
                                        frequencies: binMapper.binFrequencies
                                )
                        } else {
                                // If no binMapper, use raw spectrum data
                                if !self.study.targetOriginalSpectrum.isEmpty &&
                                        self.study.targetOriginalSpectrum.count == self.study.targetFrequencies.count {
                                        self.anfState.updateSpectrum(
                                                amplitudes: self.study.targetOriginalSpectrum,
                                                frequencies: self.study.targetFrequencies
                                        )
                                }
                        }
                }
        }
}

// MARK: - Updated Study View
struct StudyView: View {
        @ObservedObject var study: Study
        @ObservedObject var store: TuningParameterStore
        
        var body: some View {
                GeometryReader { geometry in
                        VStack(spacing: 0) {
                                // Header
                                headerView()
                                        .frame(height: 30)
                                        .background(Color.black.opacity(0.8))
                                
                                GraphView(study: study, store: store)
                                        .frame(maxHeight: .infinity)
                        }
                }
        }
        
        private func headerView() -> some View {
                HStack {
                        Text(String(format: "Target: %.2f Hz", self.store.targetFrequency()))
                                .font(.caption)
                                .foregroundColor(.white)
                        
                        Spacer()
                }
                .padding(.horizontal)
        }
}

// MARK: - Simple Plot Data Structure
struct Plot {
        var current: [Float] = []
        var target: [Float] = []
        var frequencies: [Float] = []
        let color: UIColor
        let name: String
        let lineWidth: CGFloat
        
        mutating func smooth(_ factor: Float) {
                guard self.current.count == self.target.count else {
                        self.current = self.target
                        return
                }
                let beta = 1.0 - factor
                for i in 0..<self.current.count {
                        self.current[i] = self.current[i] * factor + self.target[i] * beta
                }
        }
}
