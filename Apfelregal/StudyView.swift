// New version with Original Spectrum added

import SwiftUI
import Charts
import Accelerate

struct PLLBar: Identifiable {
        let id: String
        let frequency: Float
        let amplitude: Float
        let partialIndex: Int
        let lockStrength: Float
        
        var color: Color {
                // Color based on lock strength: red (weak) -> yellow -> green (strong)
                let hue = Double(lockStrength) * 0.33 // 0 to 0.33 (red to green)
                return Color(hue: hue, saturation: 0.8, brightness: 0.9)
        }
}

// MARK: - PLL Visualization State
class PLLVisualizationState: ObservableObject {
        @Published var smoothedBars: [PLLBar] = []
        @Published var smoothingFactor: Double = 0.85
        @Published var originalSpectrum: Plot?
        
        private var barHistory: [String: (frequency: Float, amplitude: Float)] = [:]
        
        init() {
                // Initialize original spectrum plot
                originalSpectrum = Plot(
                        color: UIColor.systemBlue.withAlphaComponent(0.5),
                        name: "Original",
                        lineWidth: 0.8
                )
        }
        
        func update(from estimates: [Int: [PartialEstimate]]) {
                var newBars: [PLLBar] = []
                
                // Convert estimates to bars
                for (partialIndex, partialEstimates) in estimates {
                        for (i, estimate) in partialEstimates.enumerated() {
                                let id = "\(partialIndex)-\(i)"
                                
                                // Get smoothed values
                                let (smoothedFreq, smoothedAmp) = smoothValues(
                                        id: id,
                                        frequency: estimate.frequency,
                                        amplitude: estimate.amplitude
                                )
                                
                                let bar = PLLBar(
                                        id: id,
                                        frequency: smoothedFreq,
                                        amplitude: smoothedAmp,
                                        partialIndex: partialIndex,
                                        lockStrength: estimate.lockStrength
                                )
                                
                                newBars.append(bar)
                        }
                }
                
                // Sort by frequency for stable rendering
                smoothedBars = newBars.sorted { $0.frequency < $1.frequency }
        }
        
        func updateSpectrum(amplitudes: [Float], frequencies: [Float]) {
                guard var spectrum = originalSpectrum,
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
                spectrum.smooth(Float(smoothingFactor))
                
                // Update the published property
                originalSpectrum = spectrum
        }
        
        private func smoothValues(id: String, frequency: Float, amplitude: Float) -> (Float, Float) {
                let alpha = Float(smoothingFactor)
                
                if let history = barHistory[id] {
                        // Apply exponential smoothing
                        let smoothedFreq = alpha * history.frequency + (1 - alpha) * frequency
                        let smoothedAmp = alpha * history.amplitude + (1 - alpha) * amplitude
                        
                        barHistory[id] = (smoothedFreq, smoothedAmp)
                        return (smoothedFreq, smoothedAmp)
                } else {
                        // First time seeing this bar
                        barHistory[id] = (frequency, amplitude)
                        return (frequency, amplitude)
                }
        }
        
        func clearHistory() {
                barHistory.removeAll()
        }
}


// MARK: - Zoom State (keeping from old file)
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
        @StateObject private var pllState = PLLVisualizationState()
        @State private var zoomState: ZoomState = .fullSpectrum
        @State private var showSettings = false
        
        var frequencyRange: ClosedRange<Double> {
                store.currentMinFreq...store.currentMaxFreq
        }
        
        var body: some View {
                GeometryReader { geometry in
                        ZStack {
                                // Background
                                Rectangle()
                                        .fill(Color.black.opacity(0.9))
                                
                                // Main plot
                                plotView(size: geometry.size)
                                
                                // Overlays
                                VStack {
                                        HStack {
                                                legendView()
                                                        .padding(.leading, 10)
                                                        .padding(.top, 5)
                                                Spacer()
                                        }
                                        
                                        Spacer()
                                        
                                        frequencyRangeDisplay()
                                                .padding()
                                }
                                
                                // Single zoom button in top-right corner
                                VStack {
                                        HStack {
                                                Spacer()
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
                                        Spacer()
                                }
                        }
                        .onAppear {
                                study.start()
                                startUpdating()
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                                showSettings = true
                        }
                }
                .sheet(isPresented: $showSettings) {
                        SettingsModalView(store: store, pllState: pllState)
                }
        }
        
        private func cycleZoom() {
                let currentIndex = zoomState.rawValue
                let nextIndex = (currentIndex + 1) % ZoomState.allCases.count
                zoomState = ZoomState.allCases[nextIndex]
                setZoomState(zoomState)
        }
        
        private func plotView(size: CGSize) -> some View {
                Canvas { context, canvasSize in
                        // Draw grid
                        drawGrid(context: context, size: canvasSize)
                        
                        // Draw original spectrum (behind PLL bars)
                        drawOriginalSpectrum(context: context, size: canvasSize)
                        
                        // Draw PLL bars
                        drawPLLBars(context: context, size: canvasSize)
                        
                        // Draw axes
                        drawAxes(context: context, size: canvasSize)
                }
        }
        
        private func drawOriginalSpectrum(context: GraphicsContext, size: CGSize) {
                guard let spectrum = pllState.originalSpectrum,
                      !spectrum.current.isEmpty,
                      spectrum.current.count == spectrum.frequencies.count else { return }
                
                let freqRange = frequencyRange
                let minDB: Float = -80
                let maxDB: Float = 180
                
                var path = Path()
                var started = false
                
                for (i, amplitude) in spectrum.current.enumerated() {
                        let freq = spectrum.frequencies[i]
                        
                        // Skip frequencies outside visible range
                        guard Double(freq) >= freqRange.lowerBound &&
                                Double(freq) <= freqRange.upperBound else { continue }
                        
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
        
        private func drawPLLBars(context: GraphicsContext, size: CGSize) {
                let freqRange = frequencyRange
                let logMinFreq = log10(freqRange.lowerBound)
                let logMaxFreq = log10(freqRange.upperBound)
                let logRange = logMaxFreq - logMinFreq
                
                // Fixed bar width in pixels
                let barWidth: CGFloat = 8
                
                for bar in pllState.smoothedBars {
                        // Skip bars outside visible range
                        guard Double(bar.frequency) >= freqRange.lowerBound &&
                                Double(bar.frequency) <= freqRange.upperBound else {
                                continue
                        }
                        
                        // Calculate x position (logarithmic scale)
                        let logFreq = log10(Double(bar.frequency))
                        let normalizedX = (logFreq - logMinFreq) / logRange
                        let x = CGFloat(normalizedX) * size.width
                        
                        // Calculate height (logarithmic amplitude scaling)
                        let dbValue = 20 * log10(bar.amplitude + 1e-10)
                        let normalizedHeight = (dbValue + 60) / 60 // Assuming -60dB to 0dB range
                        let height = max(0, min(1, CGFloat(normalizedHeight))) * size.height * 0.8
                        
                        // Draw bar
                        let rect = CGRect(
                                x: x - barWidth/2,
                                y: size.height - height,
                                width: barWidth,
                                height: height
                        )
                        
                        context.fill(Path(rect), with: .color(bar.color))
                        
                        // Draw partial index label if bar is tall enough
                        if height > 30 {
                                let text = Text("\(bar.partialIndex)")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                
                                context.draw(
                                        text,
                                        at: CGPoint(x: x, y: size.height - height - 10)
                                )
                        }
                }
        }
        
        private func drawGrid(context: GraphicsContext, size: CGSize) {
                let freqRange = frequencyRange
                
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
                let dbLines = stride(from: -60, through: 0, by: 10)
                
                for db in dbLines {
                        let y = size.height - (CGFloat(db + 60) / 60.0) * size.height * 0.8
                        
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
                let freqRange = frequencyRange
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
        
        // MARK: - Controls
        
        private func legendView() -> some View {
                VStack(alignment: .leading, spacing: 4) {
                        // Original spectrum legend
                        HStack(spacing: 4) {
                                Rectangle()
                                        .fill(Color.blue.opacity(0.5))
                                        .frame(width: 20, height: 2)
                                Text("Original Spectrum")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                        }
                        
                        Text("PLL Lock Strength")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.top, 4)
                        
                        HStack(spacing: 2) {
                                ForEach(0..<10) { i in
                                        Rectangle()
                                                .fill(Color(hue: Double(i) * 0.033, saturation: 0.8, brightness: 0.9))
                                                .frame(width: 15, height: 10)
                                }
                        }
                        
                        HStack {
                                Text("Weak")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                Spacer()
                                Text("Strong")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                        }
                        .frame(width: 150)
                }
                .padding(8)
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
        }
        
        private func frequencyRangeDisplay() -> some View {
                HStack {
                        Text(String(format: "%.1f Hz", frequencyRange.lowerBound))
                        Spacer()
                        Text("Frequency Range")
                                .foregroundColor(.gray)
                        Spacer()
                        Text(String(format: "%.1f Hz", frequencyRange.upperBound))
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
        }
        
        // MARK: - Zoom Functions (Fixed)
        
        private func setZoomState(_ state: ZoomState) {
                switch state {
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
        
        // MARK: - Updates
        
        private func startUpdating() {
                Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { _ in
                        // Update PLL bars
                        print("🎨 Current PLL estimates: \(study.currentPLLEstimates.count)")

                        pllState.update(from: study.currentPLLEstimates)
                        
                        if !study.targetOriginalSpectrum.isEmpty {
                                print("🎨 Updating spectrum with \(study.targetOriginalSpectrum.count) points")
                        }
                        
                        // Update spectrum if available
                        if let binMapper = study.binMapper,
                           !study.targetOriginalSpectrum.isEmpty,
                           study.targetOriginalSpectrum.count == study.targetFrequencies.count {
                                
                                // Map the full spectrum to display bins
                                let mappedSpectrum = binMapper.mapSpectrum(study.targetOriginalSpectrum)
                                
                                // Update the visualization state with mapped spectrum
                                pllState.updateSpectrum(
                                        amplitudes: mappedSpectrum,
                                        frequencies: binMapper.binFrequencies
                                )
                        } else {
                                // If no binMapper, use raw spectrum data
                                if !study.targetOriginalSpectrum.isEmpty &&
                                        study.targetOriginalSpectrum.count == study.targetFrequencies.count {
                                        pllState.updateSpectrum(
                                                amplitudes: study.targetOriginalSpectrum,
                                                frequencies: study.targetFrequencies
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
                                        .frame(height: 60)
                                        .background(Color.black.opacity(0.8))
                                
                                // Main graph takes all remaining space
                                GraphView(study: study, store: store)
                                        .frame(maxHeight: .infinity)
                        }
                }
        }
        
        private func headerView() -> some View {
                HStack {
                        VStack(alignment: .leading) {
                                Text("PLL Frequency Tracker")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                
                                Text(String(format: "Target: %.2f Hz", store.targetFrequency()))
                                        .font(.caption)
                                        .foregroundColor(.gray)
                        }
                        
                        Spacer()
                        
                        // Status indicators
                        HStack(spacing: 16) {
                                statusIndicator(
                                        label: "PLLs Active",
                                        value: "\(study.currentPLLEstimates.count)",
                                        color: .green
                                )
                                
                                statusIndicator(
                                        label: "Processing",
                                        value: study.isProcessing ? "ON" : "OFF",
                                        color: study.isProcessing ? .green : .gray
                                )
                        }
                }
                .padding(.horizontal)
                .foregroundColor(.white)
        }
        
        private func statusIndicator(label: String, value: String, color: Color) -> some View {
                VStack(alignment: .trailing, spacing: 2) {
                        Text(label)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        Text(value)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(color)
                }
        }
}

// MARK: - Simple Plot Data Structure (Enhanced)
struct Plot {
        var current: [Float] = []
        var target: [Float] = []
        var frequencies: [Float] = []  // Added to store frequency values
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

// MARK: - Settings Modal (Updated with smoothing control)
struct SettingsModalView: View {
        @ObservedObject var store: TuningParameterStore
        @ObservedObject var pllState: PLLVisualizationState
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
                                
                                Section("Display Parameters") {
                                        VStack(alignment: .leading) {
                                                Text("PLL Smoothing: \(pllState.smoothingFactor, specifier: "%.2f")")
                                                        .font(.caption)
                                                Slider(value: $pllState.smoothingFactor, in: 0...1)
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
