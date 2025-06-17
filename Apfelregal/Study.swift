import Foundation
import SwiftUICore
import Accelerate
import CoreML

// MARK: - New Study Result
struct StudyResult {
        let pllEstimates: [Int: [PartialEstimate]]  // Partial index -> frequency estimates
        let filteredAudio: [Float]                   // Latest filtered audio window
        let filterBandwidth: (min: Double, max: Double)
        let timestamp: Date
        let processingTime: TimeInterval
}

// MARK: - Filtered Circular Buffer
final class FilteredCircularBuffer {
        private let capacity: Int
        private let buffer: UnsafeMutableBufferPointer<Float>
        private var writeIndex = 0
        private var totalWritten = 0
        private let lock = NSLock()
        
        // Filter state
        private var filter: ButterworthBandpassFilter?
        private var cachedMinFreq: Double = 0
        private var cachedMaxFreq: Double = 0
        private let sampleRate: Double
        
        init(capacity: Int, sampleRate: Double) {
                self.capacity = capacity
                self.sampleRate = sampleRate
                let ptr = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
                self.buffer = UnsafeMutableBufferPointer(start: ptr, count: capacity)
                buffer.initialize(repeating: 0)
        }
        
        deinit {
                buffer.deallocate()
        }
        
        /// Update filter if frequency range changed
        func updateFilter(minFreq: Double, maxFreq: Double, refilter: Bool = false) {
                lock.lock()
                defer { lock.unlock() }
                
                // Check if we need to update
                if minFreq == cachedMinFreq && maxFreq == cachedMaxFreq && filter != nil {
                        return // No change needed
                }
                
                // Update filter
                cachedMinFreq = minFreq
                cachedMaxFreq = maxFreq
                filter = ButterworthBandpassFilter(
                        sampleRate: sampleRate,
                        lowFreq: minFreq,
                        highFreq: maxFreq,
                        order: 4
                )
                
                // Optionally refilter existing buffer contents
                if refilter && totalWritten > 0 {
                        refilterBuffer()
                }
        }
        
        /// Update from raw audio buffer
        func updateFromRawBuffer(_ rawSamples: [Float]) {
                lock.lock()
                defer { lock.unlock() }
                
                guard let filter = filter else {
                        // No filter set - just copy raw samples
                        writeSamples(rawSamples)
                        return
                }
                
                // Apply filter
                let filtered = filter.process(rawSamples)
                writeSamples(filtered)
        }
        
        /// Get latest filtered samples
        func getLatest(size: Int) -> [Float]? {
                lock.lock()
                defer { lock.unlock() }
                
                guard totalWritten >= size else { return nil }
                
                var result = [Float](repeating: 0, count: size)
                let readStart = (writeIndex - size + capacity) % capacity
                
                // Read in up to two chunks
                let firstChunkSize = min(size, capacity - readStart)
                for i in 0..<firstChunkSize {
                        result[i] = buffer[readStart + i]
                }
                
                if size > firstChunkSize {
                        let secondChunkSize = size - firstChunkSize
                        for i in 0..<secondChunkSize {
                                result[firstChunkSize + i] = buffer[i]
                        }
                }
                
                return result
        }
        
        private func writeSamples(_ samples: [Float]) {
                var samplesRemaining = samples.count
                var sourceOffset = 0
                
                while samplesRemaining > 0 {
                        let chunkSize = min(samplesRemaining, capacity - writeIndex)
                        for i in 0..<chunkSize {
                                buffer[writeIndex + i] = samples[sourceOffset + i]
                        }
                        
                        writeIndex = (writeIndex + chunkSize) % capacity
                        sourceOffset += chunkSize
                        samplesRemaining -= chunkSize
                }
                
                totalWritten += samples.count
        }
        
        private func refilterBuffer() {
                guard let filter = filter, totalWritten > 0 else { return }
                
                // Extract current buffer contents
                let size = min(totalWritten, capacity)
                var temp = [Float](repeating: 0, count: size)
                let readStart = (writeIndex - size + capacity) % capacity
                
                // Copy to temp buffer
                let firstChunkSize = min(size, capacity - readStart)
                for i in 0..<firstChunkSize {
                        temp[i] = buffer[readStart + i]
                }
                if size > firstChunkSize {
                        for i in 0..<(size - firstChunkSize) {
                                temp[firstChunkSize + i] = buffer[i]
                        }
                }
                
                // Refilter in place
                let refiltered = filter.process(temp)
                
                // Write back
                writeIndex = 0
                writeSamples(refiltered)
        }
}

// MARK: - Simple Butterworth Bandpass Filter
final class ButterworthBandpassFilter {
        private let coefficients: FilterCoefficients
        private var state: FilterState
        
        struct FilterCoefficients {
                let b: [Float]  // Numerator coefficients
                let a: [Float]  // Denominator coefficients
        }
        
        struct FilterState {
                var x: [Float]  // Input history
                var y: [Float]  // Output history
        }
        
        init(sampleRate: Double, lowFreq: Double, highFreq: Double, order: Int) {
                // Design Butterworth bandpass filter
                // This is simplified - in practice you'd use a proper filter design algorithm
                let nyquist = sampleRate / 2.0
                let lowNorm = lowFreq / nyquist
                let highNorm = highFreq / nyquist
                
                // For now, simple 2nd order sections
                // In production, use vDSP or Accelerate filter design functions
                self.coefficients = FilterCoefficients(
                        b: [0.1, 0.0, -0.1],
                        a: [1.0, -1.8, 0.81]
                )
                
                self.state = FilterState(
                        x: [Float](repeating: 0, count: coefficients.b.count),
                        y: [Float](repeating: 0, count: coefficients.a.count)
                )
        }
        
        func process(_ input: [Float]) -> [Float] {
                var output = [Float](repeating: 0, count: input.count)
                
                for i in 0..<input.count {
                        // Shift state
                        for j in (1..<state.x.count).reversed() {
                                state.x[j] = state.x[j-1]
                        }
                        state.x[0] = input[i]
                        
                        // Compute output
                        var y: Float = 0
                        for j in 0..<coefficients.b.count {
                                y += coefficients.b[j] * state.x[j]
                        }
                        for j in 1..<coefficients.a.count {
                                y -= coefficients.a[j] * state.y[j]
                        }
                        
                        // Shift output state
                        for j in (1..<state.y.count).reversed() {
                                state.y[j] = state.y[j-1]
                        }
                        state.y[0] = y
                        
                        output[i] = y
                }
                
                return output
        }
}

// MARK: - New Study Class
final class Study: ObservableObject {
        // Core components (owned)
        private let audioProcessor: AudioProcessor
        private let store: TuningParameterStore
        private let filteredBuffer: FilteredCircularBuffer
        private let organTunerModule: OrganTunerModule
        
        // Processing queue
        private let studyQueue = DispatchQueue(label: "com.app.study", qos: .userInitiated)
        
        // State
        private var isRunning = false
        private let updateRate: Double = 30.0  // Hz
        
        // Cached results
        @Published var latestResult: StudyResult?
        @Published var currentPLLEstimates: [Int: [PartialEstimate]] = [:]
        @Published var currentFilteredAudio: [Float] = []
        @Published var isProcessing = false
        
        init(store: TuningParameterStore) {
                self.store = store
                self.audioProcessor = AudioProcessor(store: store)
                self.filteredBuffer = FilteredCircularBuffer(
                        capacity: store.circularBufferSize,
                        sampleRate: store.audioSampleRate
                )
                self.organTunerModule = OrganTunerModule(
                        sampleRate: Float(store.audioSampleRate),
                        store: store
                )
        }
        
        // MARK: - Start / Stop
        
        func start() {
                guard !isRunning else { return }
                
                // Start audio processor
                audioProcessor.start()
                
                isRunning = true
                
                // Start processing loop
                studyQueue.async { [weak self] in
                        self?.processingLoop()
                }
        }
        
        func stop() {
                isRunning = false
                audioProcessor.stop()
        }
        
        // MARK: - Main Processing Loop
        
        private func processingLoop() {
                while isRunning {
                        autoreleasepool {
                                perform()
                        }
                        Thread.sleep(forTimeInterval: 1.0 / updateRate)
                }
        }
        
        // MARK: - Main Analysis Method
        
        func perform() {
                let startTime = CFAbsoluteTimeGetCurrent()
                
                // Update filter based on current frequency range
                filteredBuffer.updateFilter(
                        minFreq: store.currentMinFreq,
                        maxFreq: store.currentMaxFreq
                )
                
                // Get latest raw audio from audio processor
                guard let rawAudio = audioProcessor.getWindow(size: store.fftSize) else {
                        return // Not enough data yet
                }
                
                // Update filtered buffer
                filteredBuffer.updateFromRawBuffer(rawAudio)
                
                // Get filtered audio for PLL processing
                guard let filteredAudio = filteredBuffer.getLatest(size: store.fftSize) else {
                        return
                }
                
                // Get target frequency and filter bounds
                let targetFreq = Float(store.targetFrequency())
                let minFreq = Float(store.currentMinFreq)
                let maxFreq = Float(store.currentMaxFreq)
                
                // Determine which partials are within filter bounds
                let (activePartials, expectedPeaks) = calculateActivePartialsInBounds(
                        targetFreq: targetFreq,
                        minFreq: minFreq,
                        maxFreq: maxFreq
                )
                
                // Run organ tuner analysis
                let pllEstimates = organTunerModule.processAudioBlock(
                        audioSamples: filteredAudio,
                        targetPitch: targetFreq,
                        partialIndices: activePartials,
                        expectedPeaksPerPartial: expectedPeaks
                )
                
                // Create result
                let result = StudyResult(
                        pllEstimates: pllEstimates,
                        filteredAudio: filteredAudio,
                        filterBandwidth: (min: store.currentMinFreq, max: store.currentMaxFreq),
                        timestamp: Date(),
                        processingTime: CFAbsoluteTimeGetCurrent() - startTime
                )
                
                // Update published properties on main queue
                DispatchQueue.main.async { [weak self] in
                        self?.latestResult = result
                        self?.currentPLLEstimates = pllEstimates
                        self?.currentFilteredAudio = filteredAudio
                        self?.isProcessing = false
                }
        }
        
        // MARK: - Helper Methods
        
        private func calculateActivePartialsInBounds(
                targetFreq: Float,
                minFreq: Float,
                maxFreq: Float
        ) -> (partials: [Int], expectedPeaks: [Int: Int]) {
                
                // Get overtone stack for the instrument
                // Using typical organ configuration: 8 pipes, up to 16 partials
                let maxPipes = 8  // Could make this configurable
                let maxPartials = 16
                let overtoneStack = self.overtoneStack(pipes: maxPipes, partials: maxPartials)
                
                // Build frequency count map
                var freqCountMap: [Int: Int] = [:]
                for (freq, count) in overtoneStack {
                        freqCountMap[freq] = count
                }
                
                // Find partials within bounds
                var activePartials: [Int] = []
                var expectedPeaks: [Int: Int] = [:]
                
                for partial in 1...maxPartials {
                        let partialFreq = targetFreq * Float(partial)
                        
                        // Check if this partial is within filter bounds
                        if partialFreq >= minFreq && partialFreq <= maxFreq {
                                activePartials.append(partial)
                                
                                // Get expected peaks from overtone stack
                                expectedPeaks[partial] = freqCountMap[partial] ?? 1
                        }
                }
                
                return (activePartials, expectedPeaks)
        }
        
        private func overtoneStack(pipes: Int, partials: Int) -> [(Int, Int)] {
                var freqCounts: [Int: Int] = [:]
                for i in 1...pipes {
                        for j in 1...partials {
                                let freq = i * j
                                freqCounts[freq, default: 0] += 1
                        }
                }
                return freqCounts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        
        // MARK: - Public Query Methods
        
        func getLatestPLLEstimates() -> [Int: [PartialEstimate]] {
                return currentPLLEstimates
        }
        
        func getLatestFilteredAudio() -> [Float] {
                return currentFilteredAudio
        }
        
        func getFilterBandwidth() -> (min: Double, max: Double) {
                return (min: store.currentMinFreq, max: store.currentMaxFreq)
        }
}
