import Foundation
import SwiftUICore
import Accelerate
import CoreML

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
                // For now, just pass through the audio unfiltered
                // TODO: Implement proper Butterworth filter design
                return input
        }
}



// MARK: - Filtered Circular Buffer (Redesigned)
final class FilteredCircularBuffer {
        private let capacity: Int
        private let buffer: UnsafeMutableBufferPointer<Float>
        private var writeIndex = 0
        private var totalWritten = 0
        private let lock = NSLock()
        
        // Reference to audio processor
        private weak var audioProcessor: AudioProcessor?
        
        // Tracking position in source
        private var lastReadPosition = 0
        
        // Filter state
        private var filter: ButterworthBandpassFilter?
        private var cachedMinFreq: Double = 0
        private var cachedMaxFreq: Double = 0
        private let sampleRate: Double
        
        init(capacity: Int, sampleRate: Double, audioProcessor: AudioProcessor) {
                self.capacity = capacity
                self.sampleRate = sampleRate
                self.audioProcessor = audioProcessor
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
                if minFreq == cachedMinFreq && maxFreq == cachedMaxFreq && filter != nil && !refilter {
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
                
                // Refilter from raw source if requested
                if refilter {
                        refilterFromSource()
                }
        }
        
        /// Update from audio processor (only new samples)
        func updateFromAudioProcessor() {
                lock.lock()
                defer { lock.unlock() }
                
                guard let audioProcessor = audioProcessor,
                      let filter = filter else { return }
                
                // Get new samples since our last position
                guard let (newSamples, newPosition) = audioProcessor.getSamplesSince(position: lastReadPosition) else {
                        return // No new samples
                }
                
                // Update our position
                lastReadPosition = newPosition
                
                // Apply filter to new samples
                let filtered = filter.process(newSamples)
                
                // Write filtered samples to our buffer
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
        
        /// Refilter entire buffer from raw source
        private func refilterFromSource() {
                guard let audioProcessor = audioProcessor,
                      let filter = filter else { return }
                
                // Get all raw samples
                let rawSamples = audioProcessor.getAllRawSamples()
                guard !rawSamples.isEmpty else { return }
                
                // Apply filter to all samples
                let filtered = filter.process(rawSamples)
                
                // Reset buffer and write all filtered samples
                writeIndex = 0
                totalWritten = 0
                writeSamples(filtered)
                
                // Update our position to current
                lastReadPosition = audioProcessor.getCurrentPosition()
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
        
        func hasEnoughData(size: Int) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return totalWritten >= size
        }
}
final class FFTProcessor {
        let fftSize: Int
        let halfSize: Int
        private let log2n: vDSP_Length
        
        // FFT setup
        private let fftSetup: FFTSetup
        
        // Split complex buffers
        private let splitReal: UnsafeMutablePointer<Float>
        private let splitImag: UnsafeMutablePointer<Float>
        private var splitComplex: DSPSplitComplex
        
        // Temp workspace
        private let tempReal: UnsafeMutablePointer<Float>
        private let tempImag: UnsafeMutablePointer<Float>
        private var tempSplit: DSPSplitComplex
        
        // Processing buffers
        let windowBuffer: UnsafeMutablePointer<Float>
        let windowedBuffer: UnsafeMutablePointer<Float>
        let magnitudeBuffer: UnsafeMutablePointer<Float>
        let frequencyBuffer: UnsafeMutablePointer<Float>
        
        init(fftSize: Int) {
                self.fftSize = fftSize
                self.halfSize = fftSize / 2
                self.log2n = vDSP_Length(log2(Float(fftSize)))
                
                // Create FFT setup
                guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                        fatalError("Failed to create FFT setup")
                }
                self.fftSetup = setup
                
                // Allocate split complex
                self.splitReal = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.splitImag = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.splitReal.initialize(repeating: 0, count: halfSize)
                self.splitImag.initialize(repeating: 0, count: halfSize)
                self.splitComplex = DSPSplitComplex(realp: splitReal, imagp: splitImag)
                
                // Allocate temp workspace
                self.tempReal = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.tempImag = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.tempReal.initialize(repeating: 0, count: halfSize)
                self.tempImag.initialize(repeating: 0, count: halfSize)
                self.tempSplit = DSPSplitComplex(realp: tempReal, imagp: tempImag)
                
                // Allocate processing buffers
                self.windowBuffer = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
                self.windowedBuffer = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
                self.magnitudeBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.frequencyBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                
                self.magnitudeBuffer.initialize(repeating: 0, count: halfSize)
                self.frequencyBuffer.initialize(repeating: 0, count: halfSize)
        }
        
        deinit {
                vDSP_destroy_fftsetup(fftSetup)
                splitReal.deallocate()
                splitImag.deallocate()
                tempReal.deallocate()
                tempImag.deallocate()
                windowBuffer.deallocate()
                windowedBuffer.deallocate()
                magnitudeBuffer.deallocate()
                frequencyBuffer.deallocate()
        }
        
        // Commented out - keeping for potential future use
        /*
         func initializeBlackmanHarrisWindow() {
         let a0: Float = 0.35875
         let a1: Float = 0.48829
         let a2: Float = 0.14128
         let a3: Float = 0.01168
         
         for i in 0..<fftSize {
         let n = Float(i)
         let N = Float(fftSize - 1)
         let term1 = a1 * cos(2.0 * .pi * n / N)
         let term2 = a2 * cos(4.0 * .pi * n / N)
         let term3 = a3 * cos(6.0 * .pi * n / N)
         windowBuffer[i] = a0 - term1 + term2 - term3
         }
         }
         */
        
        func initializeFrequencies(sampleRate: Float) {
                let binWidth = sampleRate / Float(fftSize)
                for i in 0..<halfSize {
                        frequencyBuffer[i] = Float(i) * binWidth // 1024 * (22050 / 2048)
                }
        }
        
        func performFFT(input: UnsafePointer<Float>, applyWindow: Bool = true) {
                // Apply window if requested
                if applyWindow {
                        vDSP_vmul(input, 1, windowBuffer, 1, windowedBuffer, 1, vDSP_Length(fftSize))
                } else {
                        memcpy(windowedBuffer, input, fftSize * MemoryLayout<Float>.size)
                }
                
                // Pack real data into split complex
                windowedBuffer.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfSize))
                }
                
                // Forward FFT
                vDSP_fft_zript(
                        fftSetup,
                        &splitComplex,
                        1,
                        &tempSplit,
                        log2n,
                        FFTDirection(FFT_FORWARD)
                )
                
                // Compute magnitudes
                vDSP_zvmags(&splitComplex, 1, magnitudeBuffer, 1, vDSP_Length(halfSize))
                
                // Scale by 2/N
                var scaleFactor: Float = 2.0 / Float(fftSize)
                vDSP_vsmul(magnitudeBuffer, 1, &scaleFactor, magnitudeBuffer, 1, vDSP_Length(halfSize))
        }
        
        func convertMagnitudesToDB() {
                var floorDB: Float = 1e-10
                var ceilingDB: Float = .greatestFiniteMagnitude
                vDSP_vclip(magnitudeBuffer, 1, &floorDB, &ceilingDB, magnitudeBuffer, 1, vDSP_Length(halfSize))
                
                var reference: Float = 1.0
                vDSP_vdbcon(magnitudeBuffer, 1, &reference, magnitudeBuffer, 1, vDSP_Length(halfSize), 1)
        }
}


struct StudyResult {
        let pllEstimates: [Int: [PartialEstimate]]  // Partial index -> frequency estimates
        let filteredAudio: [Float]                   // Latest filtered audio window
        let filterBandwidth: (min: Double, max: Double)
        let timestamp: Date
        let processingTime: TimeInterval
}


// MARK: - New Study Class
final class Study: ObservableObject {
        // Core components (owned)
        private let audioProcessor: AudioProcessor
        private let store: TuningParameterStore
        private let filteredBuffer: FilteredCircularBuffer
        private let organTunerModule: OrganTunerModule
        private let fftProcessor: FFTProcessor
        
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
        
        // FFT spectrum data
        @Published var targetOriginalSpectrum: [Float] = []
        @Published var targetFrequencies: [Float] = []
        var binMapper: BinMapper?
        
        init(store: TuningParameterStore) {
                self.store = store
                self.audioProcessor = AudioProcessor(store: store)
                self.filteredBuffer = FilteredCircularBuffer(
                        capacity: store.circularBufferSize,
                        sampleRate: store.audioSampleRate,
                        audioProcessor: audioProcessor
                )
                self.organTunerModule = OrganTunerModule(
                        sampleRate: Float(store.audioSampleRate),
                        store: store
                )
                
                // Initialize FFT processor
                self.fftProcessor = FFTProcessor(fftSize: store.fftSize)
                
                // Initialize FFT components
                // Comment out window initialization since we're not using it
                // fftProcessor.initializeBlackmanHarrisWindow()
                fftProcessor.initializeFrequencies(sampleRate: Float(store.audioSampleRate))
                
                // Initialize BinMapper with correct parameters
                self.binMapper = BinMapper(
                        store: store,
                        halfSize: store.fftSize / 2
                )
        }
        
        // MARK: - Start / Stop
        
        func start() {
                
                guard !isRunning else { return }
                print("▶️ audioProcessor.start() called")
                filteredBuffer.updateFilter(
                        minFreq: store.currentMinFreq,
                        maxFreq: store.currentMaxFreq
                )
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
        
        // MARK: - Main Analysis Method (Enhanced with FFT)
        
        func perform() {
                DispatchQueue.main.async { [weak self] in
                        self?.isProcessing = true
                }
                let startTime = CFAbsoluteTimeGetCurrent()
                
                // Update filter based on current frequency range
                filteredBuffer.updateFilter(
                        minFreq: store.currentMinFreq,
                        maxFreq: store.currentMaxFreq
                )
                
                // Update filtered buffer with any new audio
                filteredBuffer.updateFromAudioProcessor()
                
                // Get filtered audio for processing
                guard let filteredAudio = filteredBuffer.getLatest(size: store.fftSize) else {
                        return // Not enough data yet
                }
                
                // Perform FFT on filtered audio (no windowing)
                filteredAudio.withUnsafeBufferPointer { audioPtr in
                        fftProcessor.performFFT(input: audioPtr.baseAddress!, applyWindow: false)
                }
                
                // Convert to dB scale
                fftProcessor.convertMagnitudesToDB()
                
                // Copy FFT results
                let spectrumData = Array(UnsafeBufferPointer(
                        start: fftProcessor.magnitudeBuffer,
                        count: fftProcessor.halfSize
                ))
                let frequencyData = Array(UnsafeBufferPointer(
                        start: fftProcessor.frequencyBuffer,
                        count: fftProcessor.halfSize
                ))
                
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
                        self?.targetOriginalSpectrum = spectrumData
                        self?.targetFrequencies = frequencyData
                        self?.isProcessing = false
                        
                        print("📊 Filtered audio samples: \(filteredAudio.count)")
                        print("📊 PLL estimates count: \(pllEstimates.count)")
                        print("📊 Spectrum data points: \(spectrumData.count)")
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
        
        // MARK: - Filter Management
        
        func refilterAll() {
                filteredBuffer.updateFilter(
                        minFreq: store.currentMinFreq,
                        maxFreq: store.currentMaxFreq,
                        refilter: true
                )
        }
}
