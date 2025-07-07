import SwiftUI
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

// MARK: - Updated Graph View
struct GraphView: View {
        @ObservedObject var study: Study
        @ObservedObject var store: TuningParameterStore
        @State private var zoomState: ZoomState = .fullSpectrum
        
        var frequencyRange: ClosedRange<Double> {
                store.viewportMinFreq...store.viewportMaxFreq
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
                        }
                        .onChange(of: store.targetNote) { _ in
                                updateZoomBounds()
                        }
                        .onChange(of: store.concertPitch) { _ in
                                updateZoomBounds()
                        }
                        .onChange(of: store.targetPartial) { _ in
                                updateZoomBounds()
                        }
                }
        }
        
        private func updateZoomBounds() {
                // Only update if we're in a zoom state that depends on target frequency
                if zoomState != .fullSpectrum {
                        setZoomState(zoomState)
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
                        drawGrid(context: context, size: canvasSize)
                        drawSpectrum(context: context, size: canvasSize)
                        drawAxes(context: context, size: canvasSize)
                }
        }
        
        private func drawSpectrum(context: GraphicsContext, size: CGSize) {
                guard let results = study.results,
                      !results.logDecimatedSpectrum.isEmpty,
                      results.logDecimatedSpectrum.count == results.logDecimatedFrequencies.count else { return }
                
                let freqRange = frequencyRange
                let maxDB = store.maxDB
                let minDB = store.minDB

                var path = Path()
                var started = false
                
                // Find the indices for one point before and after the visible range
                var startIndex = 0
                var endIndex = results.logDecimatedFrequencies.count - 1
                
                // Find the last point before the range
                for i in 0..<results.logDecimatedFrequencies.count {
                        if results.logDecimatedFrequencies[i] >= freqRange.lowerBound {
                                startIndex = max(0, i - 1)
                                break
                        }
                }
                
                // Find the first point after the range
                for i in (0..<results.logDecimatedFrequencies.count).reversed() {
                        if results.logDecimatedFrequencies[i] <= freqRange.upperBound {
                                endIndex = min(results.logDecimatedFrequencies.count - 1, i + 1)
                                break
                        }
                }
                
                // Draw points from startIndex to endIndex
                for i in startIndex...endIndex {
                        let freq = results.logDecimatedFrequencies[i]
                        let amplitude = results.logDecimatedSpectrum[i]
                        
                        // Calculate x position
                        let x = frequencyToX(freq, size: size.width)
                        
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
                        with: .color(.cyan),
                        lineWidth: 2
                )
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
                let dbLines = stride(from: store.minDB, through: 0, by: 10)
                
                for db in dbLines {
                        let y = size.height - (CGFloat(db - store.minDB) / CGFloat(store.maxDB - store.minDB)) * size.height
                        
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
        
        // MARK: - Zoom Functions
        
        private func setZoomState(_ state: ZoomState) {
                switch state {
                case .fullSpectrum:
                        store.viewportMinFreq = store.fullSpectrumMinFreq
                        store.viewportMaxFreq = store.fullSpectrumMaxFreq
                        
                case .threeOctaves:
                        let baseFreq = store.targetNote.transposed(by: -1).frequency(concertA: store.concertPitch)
                        let maxFreq = store.targetNote.transposed(by: 12 * 3).frequency(concertA: store.concertPitch)
                        store.viewportMinFreq = Double(baseFreq)
                        store.viewportMaxFreq = min(Double(maxFreq), store.fullSpectrumMaxFreq)
                        
                case .targetFundamental:
                        let centerFreq = store.targetFrequency()
                        store.viewportMinFreq = centerFreq * pow(2, -50.0/1200.0)
                        store.viewportMaxFreq = centerFreq * pow(2, 50.0/1200.0)
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
                        Text(String(format: "Target: %.2f Hz", store.targetFrequency()))
                                .font(.caption)
                                .foregroundColor(.white)
                        
                        Spacer()
                        
                        if let results = study.results {
                                Text(results.isBaseband ? "Baseband" : "Full Spectrum")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                        }
                }
                .padding(.horizontal)
        }
}
