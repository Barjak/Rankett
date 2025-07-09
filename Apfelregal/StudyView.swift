import SwiftUI

struct GraphView: View {
        @ObservedObject var study: Study
        @ObservedObject var store: TuningParameterStore
        
        @State private var smoothedSpectrum: [Double] = []
        @State private var targetSpectrum: [Double] = []
        @State private var currentFrequencies: [Double] = []
        
        @State private var smoothedMUSICSpectrum: [Double] = []
        @State private var targetMUSICSpectrum: [Double] = []
        
        var frequencyRange: ClosedRange<Double> {
                store.viewportMinFreq...store.viewportMaxFreq
        }
        
        private var isUsingLogScale: Bool {
                let range = store.viewportMaxFreq / store.viewportMinFreq
                return range > 2.0 && store.useLogFrequencyScale
        }
        
        var body: some View {
                TimelineView(.animation(minimumInterval: 1.0/60.0)) { timeline in
                        GeometryReader { geometry in
                                ZStack {
                                        Rectangle()
                                                .fill(Color.black.opacity(0.9))
                                        
                                        plotView(size: geometry.size)
                                        
                                        VStack {
                                                HStack {
                                                        Spacer()
                                                        Button(action: cycleZoom) {
                                                                Image(systemName: store.zoomState.iconName)
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
                                .onChange(of: timeline.date) { _ in
                                        updateSmoothedSpectrum()
                                }
                        }
                }
                .onChange(of: study.results?.frameNumber) { _ in
                        if let results = study.results {
                                targetSpectrum = results.logDecimatedSpectrum
                                currentFrequencies = results.logDecimatedFrequencies
                                targetMUSICSpectrum = results.basebandMUSIC ?? []
                        }
                }
                .onChange(of: store.zoomState) { _ in
                        smoothedSpectrum = targetSpectrum
                        smoothedMUSICSpectrum = targetMUSICSpectrum
                }
                .onChange(of: store.displayBinCount) { _ in
                        smoothedSpectrum = []
                        targetSpectrum = []
                        currentFrequencies = []
                        smoothedMUSICSpectrum = []
                        targetMUSICSpectrum = []
                }
                .onChange(of: store.useLogFrequencyScale) { _ in
                        smoothedSpectrum = []
                        targetSpectrum = []
                        currentFrequencies = []
                        smoothedMUSICSpectrum = []
                        targetMUSICSpectrum = []
                }
                .onAppear {
                        study.start()
                }
        }
        
        private func updateSmoothedSpectrum() {
                guard !targetSpectrum.isEmpty else { return }
                
                let factor = min(max(store.animationSmoothingFactor, 0), 0.99)
                
                if smoothedSpectrum.count != targetSpectrum.count {
                        smoothedSpectrum = targetSpectrum
                } else {
                        for i in 0..<smoothedSpectrum.count {
                                smoothedSpectrum[i] = smoothedSpectrum[i] * factor +
                                targetSpectrum[i] * (1 - factor)
                        }
                }
                
                if !targetMUSICSpectrum.isEmpty {
                        if smoothedMUSICSpectrum.count != targetMUSICSpectrum.count {
                                smoothedMUSICSpectrum = targetMUSICSpectrum
                        } else {
                                for i in 0..<smoothedMUSICSpectrum.count {
                                        smoothedMUSICSpectrum[i] = smoothedMUSICSpectrum[i] * factor +
                                        targetMUSICSpectrum[i] * (1 - factor)
                                }
                        }
                } else {
                        smoothedMUSICSpectrum = []
                }
        }
        
        private func cycleZoom() {
                let currentIndex = store.zoomState.rawValue
                let nextIndex = (currentIndex + 1) % ZoomState.allCases.count
                store.zoomState = ZoomState.allCases[nextIndex]
        }
        
        private func plotView(size: CGSize) -> some View {
                Canvas { context, canvasSize in
                        drawGrid(context: context, size: canvasSize)
                        drawSpectrum(context: context, size: canvasSize)
                        drawMUSICSpectrum(context: context, size: canvasSize)
                        drawPeakLine(context: context, size: canvasSize)
                        drawAxes(context: context, size: canvasSize)
                }
        }
        
        private func drawMUSICSpectrum(context: GraphicsContext, size: CGSize) {
                guard !smoothedMUSICSpectrum.isEmpty,
                      !currentFrequencies.isEmpty,
                      smoothedMUSICSpectrum.count == currentFrequencies.count else { return }
                
                let freqRange = frequencyRange
                let maxDB = store.maxDB
                let minDB = store.minDB
                
                var path = Path()
                var started = false
                
                var startIndex = 0
                var endIndex = currentFrequencies.count - 1
                
                for i in 0..<currentFrequencies.count {
                        if currentFrequencies[i] >= freqRange.lowerBound {
                                startIndex = max(0, i - 1)
                                break
                        }
                }
                
                for i in (0..<currentFrequencies.count).reversed() {
                        if currentFrequencies[i] <= freqRange.upperBound {
                                endIndex = min(currentFrequencies.count - 1, i + 1)
                                break
                        }
                }
                
                // Convert normalized MUSIC values (0-1) to dB scale for display
                for i in startIndex...endIndex {
                        let freq = currentFrequencies[i]
                        let musicValue = smoothedMUSICSpectrum[i]
                        
                        // Convert to dB-like scale for display consistency
                        let dbValue = 20.0 * log10(max(musicValue, 1e-10))
                        let scaledValue = dbValue + 40.0  // Offset to bring into visible range
                        
                        let x = frequencyToX(freq, size: size.width)
                        let normalizedValue = (scaledValue - minDB) / (maxDB - minDB)
                        let y = size.height * (1 - CGFloat(normalizedValue))
                        
                        if started {
                                path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                                path.move(to: CGPoint(x: x, y: y))
                                started = true
                        }
                }
                
                context.stroke(
                        path,
                        with: .color(.purple),
                        style: StrokeStyle(lineWidth: 0.6, dash: [3, 2])
                )
        }
        
        private func drawPeakLine(context: GraphicsContext, size: CGSize) {
                guard let results = study.results,
                      !results.trackedPeaks.isEmpty,
                      let peakFreq = results.trackedPeaks.first else { return }
                
                let freqRange = frequencyRange
                
                guard peakFreq >= freqRange.lowerBound && peakFreq <= freqRange.upperBound else { return }
                
                let x = frequencyToX(peakFreq, size: size.width)
                
                context.stroke(
                        Path { path in
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: size.height))
                        },
                        with: .color(.yellow),
                        lineWidth: 0.5
                )
        }
        
        private func drawSpectrum(context: GraphicsContext, size: CGSize) {
                guard !smoothedSpectrum.isEmpty,
                      !currentFrequencies.isEmpty,
                      smoothedSpectrum.count == currentFrequencies.count else { return }
                
                let freqRange = frequencyRange
                let maxDB = store.maxDB
                let minDB = store.minDB
                
                var path = Path()
                var started = false
                
                var startIndex = 0
                var endIndex = currentFrequencies.count - 1
                
                for i in 0..<currentFrequencies.count {
                        if currentFrequencies[i] >= freqRange.lowerBound {
                                startIndex = max(0, i - 1)
                                break
                        }
                }
                
                for i in (0..<currentFrequencies.count).reversed() {
                        if currentFrequencies[i] <= freqRange.upperBound {
                                endIndex = min(currentFrequencies.count - 1, i + 1)
                                break
                        }
                }
                
                for i in startIndex...endIndex {
                        let freq = currentFrequencies[i]
                        let amplitude = smoothedSpectrum[i]
                        
                        let x = frequencyToX(freq, size: size.width)
                        let normalizedValue = (amplitude - minDB) / (maxDB - minDB)
                        let y = size.height * (1 - CGFloat(normalizedValue))
                        
                        if started {
                                path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                                path.move(to: CGPoint(x: x, y: y))
                                started = true
                        }
                }
                
                context.stroke(
                        path,
                        with: .color(.cyan),
                        lineWidth: 0.8
                )
        }
        
        private func drawGrid(context: GraphicsContext, size: CGSize) {
                let freqRange = frequencyRange
                let gridFrequencies = gridLines(min: freqRange.lowerBound, max: freqRange.upperBound)
                
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
                        
                        let text = Text("\(Int(db))dB")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        
                        context.draw(text, at: CGPoint(x: 10, y: y - 5))
                }
        }
        
        private func drawAxes(context: GraphicsContext, size: CGSize) {
                context.stroke(
                        Path { path in
                                path.move(to: CGPoint(x: 0, y: size.height))
                                path.addLine(to: CGPoint(x: size.width, y: size.height))
                        },
                        with: .color(.white),
                        lineWidth: 2
                )
                
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
                
                if isUsingLogScale {
                        let logMinFreq = log10(freqRange.lowerBound)
                        let logMaxFreq = log10(freqRange.upperBound)
                        let logRange = logMaxFreq - logMinFreq
                        let logFreq = log10(freq)
                        let normalized = (logFreq - logMinFreq) / logRange
                        return CGFloat(normalized) * size
                } else {
                        let normalized = (freq - freqRange.lowerBound) /
                        (freqRange.upperBound - freqRange.lowerBound)
                        return CGFloat(normalized) * size
                }
        }
        
        private func gridLines(min: Double, max: Double) -> [Double] {
                if !isUsingLogScale {
                        let step = (max - min) / 10
                        return stride(from: min, through: max, by: step).map { $0 }
                }
                
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
}

struct StudyView: View {
        @ObservedObject var study: Study
        @ObservedObject var store: TuningParameterStore
        
        var body: some View {
                GeometryReader { geometry in
                        VStack(spacing: 0) {
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
                                HStack(spacing: 12) {
                                        if results.basebandMUSIC != nil {
                                                Text("MUSIC")
                                                        .font(.caption)
                                                        .foregroundColor(.purple)
                                        }
                                        Text(results.isBaseband ? "Baseband" : "Full Spectrum")
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                }
                        }
                }
                .padding(.horizontal)
        }
}
