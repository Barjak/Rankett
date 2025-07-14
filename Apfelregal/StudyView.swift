import SwiftUI

struct GraphView: View {
        @ObservedObject var study: Study
        @ObservedObject var store: TuningParameterStore
        
        // Drawing constants
        private let spectrumColor = Color.cyan
        private let spectrumLineWidth: CGFloat = 0.8
        private let primaryPeakColor = Color.yellow
        private let secondaryPeakColor = Color.orange
        private let peakLineWidth: CGFloat = 0.5
        private let peakLineOpacity: Double = 0.8
        private let gridLineColor = Color.gray.opacity(0.3)
        private let gridLineWidth: CGFloat = 1
        private let axisLineColor = Color.white
        private let axisLineWidth: CGFloat = 2
        private let labelFont = Font.caption
        private let labelColor = Color.gray
        private let backgroundOpacity: Double = 0.9
        private let zoomButtonPadding: CGFloat = 12
        private let zoomButtonBackgroundOpacity: Double = 0.6
        private let dbGridStep: Double = 20.0
        private let maxPeakCount = 20
        
        struct PeakData {
                var target: Double
                var smoothed: Double
        }
        
        @State private var smoothedSpectrum: [Double] = []
        @State private var targetSpectrum: [Double] = []
        @State private var currentFrequencies: [Double] = []
        @State private var peaks: [PeakData] = Array(repeating: PeakData(target: 0, smoothed: 0), count: 20)
        
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
                                                .fill(Color.black.opacity(backgroundOpacity))
                                        
                                        plotView(size: geometry.size)
                                        
                                        VStack {
                                                HStack {
                                                        Spacer()
                                                        Button(action: cycleZoom) {
                                                                Image(systemName: store.zoomState.iconName)
                                                                        .font(.title2)
                                                                        .foregroundColor(.white)
                                                                        .padding(8)
                                                                        .background(Color.black.opacity(zoomButtonBackgroundOpacity))
                                                                        .clipShape(Circle())
                                                        }
                                                        .padding(.trailing, zoomButtonPadding)
                                                        .padding(.top, zoomButtonPadding)
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
                                
                                for i in 0..<maxPeakCount {
                                        peaks[i].target = i < results.trackedPeaks.count ? results.trackedPeaks[i] : 0
                                }
                        }
                }
                .onChange(of: store.zoomState) { _ in
                        smoothedSpectrum = targetSpectrum
                }
                .onChange(of: store.displayBinCount) { _ in
                        smoothedSpectrum = []
                        targetSpectrum = []
                        currentFrequencies = []
                }
                .onChange(of: store.useLogFrequencyScale) { _ in
                        smoothedSpectrum = []
                        targetSpectrum = []
                        currentFrequencies = []
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
                
                for i in 0..<maxPeakCount {
                        if peaks[i].target > 0 {
                                peaks[i].smoothed = peaks[i].smoothed * factor + peaks[i].target * (1 - factor)
                        } else {
                                peaks[i].smoothed = 0
                        }
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
                        drawPeakLines(context: context, size: canvasSize)
                        drawAxes(context: context, size: canvasSize)
                }
        }
        
        private func drawPeakLines(context: GraphicsContext, size: CGSize) {
                let freqRange = frequencyRange
                let targetFreq = store.targetFrequency()
                
                for index in 0..<maxPeakCount {
                        let peakFreq = peaks[index].smoothed
                        guard peakFreq > 0 && peakFreq >= freqRange.lowerBound && peakFreq <= freqRange.upperBound else { continue }
                        
                        let x = frequencyToX(peakFreq, size: size.width)
                        
                        let color: Color = index == 0 ? primaryPeakColor : secondaryPeakColor
                        
                        context.stroke(
                                Path { path in
                                        path.move(to: CGPoint(x: x, y: 0))
                                        path.addLine(to: CGPoint(x: x, y: size.height))
                                },
                                with: .color(color.opacity(peakLineOpacity)),
                                lineWidth: peakLineWidth
                        )
                        
                        let cents = 1200 * log2(peakFreq / targetFreq)
                        let text = Text(String(format: "%.2f¢", cents))
                                .font(labelFont)
                                .foregroundColor(color)
                        
                        context.draw(text, at: CGPoint(x: x + 5, y: 20 + CGFloat(index) * 15))
                }
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
                        with: .color(spectrumColor),
                        lineWidth: spectrumLineWidth
                )
        }
        
        private func drawGrid(context: GraphicsContext, size: CGSize) {
                let freqRange = frequencyRange
                let gridFrequencies = musicalGridFrequencies(min: freqRange.lowerBound, max: freqRange.upperBound)
                
                for (freq, noteName) in gridFrequencies {
                        let x = frequencyToX(freq, size: size.width)
                        
                        context.stroke(
                                Path { path in
                                        path.move(to: CGPoint(x: x, y: 0))
                                        path.addLine(to: CGPoint(x: x, y: size.height))
                                },
                                with: .color(gridLineColor),
                                lineWidth: gridLineWidth
                        )
                        
                        let text = Text(noteName)
                                .font(.caption2)
                                .foregroundColor(labelColor)
                        
                        context.draw(text, at: CGPoint(x: x, y: size.height - 10))
                }
                
                for db in stride(from: store.minDB, through: store.maxDB, by: dbGridStep) {
                        let y = size.height * (1 - CGFloat((db - store.minDB) / (store.maxDB - store.minDB)))
                        
                        context.stroke(
                                Path { path in
                                        path.move(to: CGPoint(x: 0, y: y))
                                        path.addLine(to: CGPoint(x: size.width, y: y))
                                },
                                with: .color(gridLineColor),
                                lineWidth: gridLineWidth
                        )
                        
                        let text = Text("\(Int(db))dB")
                                .font(.caption2)
                                .foregroundColor(labelColor)
                        
                        context.draw(text, at: CGPoint(x: 10, y: y - 5))
                }
        }
        
        private func drawAxes(context: GraphicsContext, size: CGSize) {
                context.stroke(
                        Path { path in
                                path.move(to: CGPoint(x: 0, y: size.height))
                                path.addLine(to: CGPoint(x: size.width, y: size.height))
                        },
                        with: .color(axisLineColor),
                        lineWidth: axisLineWidth
                )
                
                context.stroke(
                        Path { path in
                                path.move(to: CGPoint(x: 0, y: 0))
                                path.addLine(to: CGPoint(x: 0, y: size.height))
                        },
                        with: .color(axisLineColor),
                        lineWidth: axisLineWidth
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
        
        private func musicalGridFrequencies(min: Double, max: Double) -> [(frequency: Double, label: String)] {
                var lines: [(Double, String)] = []
                let concertPitch = store.concertPitch
                let range = max / min
                
                if range > 8 {
                        // Wide view: show octaves only
                        for midiNote in 0...127 {
                                if midiNote % 12 == 0 {  // C notes only
                                        let note = Note(midiNumber: midiNote)
                                        let freq = note.frequency(concertA: concertPitch)
                                        if freq >= min && freq <= max {
                                                lines.append((freq, organNotationLabel(note)))
                                        }
                                }
                        }
                } else if range > 2 {
                        // Medium view: show all C, E, G notes
                        for midiNote in 0...127 {
                                let noteInOctave = midiNote % 12
                                if noteInOctave == 0 || noteInOctave == 4 || noteInOctave == 7 {
                                        let note = Note(midiNumber: midiNote)
                                        let freq = note.frequency(concertA: concertPitch)
                                        if freq >= min && freq <= max {
                                                lines.append((freq, organNotationLabel(note)))
                                        }
                                }
                        }
                } else {
                        // Narrow view: show all semitones
                        for midiNote in 0...127 {
                                let note = Note(midiNumber: midiNote)
                                let freq = note.frequency(concertA: concertPitch)
                                if freq >= min && freq <= max {
                                        lines.append((freq, organNotationLabel(note)))
                                }
                        }
                }
                
                return lines
        }
        
        private func organNotationLabel(_ note: Note) -> String {
                let baseName = note.displayName
                let octave = note.octave
                
                if octave < 3 {
                        return baseName + String(octave - 3)
                } else if octave == 3 {
                        return baseName
                } else {
                        return baseName.lowercased() + (octave > 4 ? String(octave - 4) : "")
                }
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
                        
                        Text(zoomStateLabel)
                                .font(.caption)
                                .foregroundColor(.gray)
                }
                .padding(.horizontal)
        }
        
        private var zoomStateLabel: String {
                switch store.zoomState {
                case .fullSpectrum:
                        return "Full Spectrum"
                case .threeOctaves:
                        return "Three Octaves"
                case .targetFundamental:
                        return "Target ±\(Int(store.targetBandwidth))¢"
                }
        }
}
