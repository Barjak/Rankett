import Foundation
import SwiftUICore
import Accelerate
import CoreML

final class ButterworthBandpassFilter {
        private let coefficients: FilterCoefficients
        private var state: FilterState
        
        struct FilterCoefficients {
                let b0, b1, b2: Float
                let a1, a2: Float  // a0 is normalized to 1.0
        }
        
        struct FilterState {
                var d1: Float = 0.0
                var d2: Float = 0.0
        }
        
        init(sampleRate: Double, lowFreq: Double, highFreq: Double) {
                // Pre-warp frequencies for bilinear transform
                let fs = sampleRate
                let wl = 2.0 * Double.pi * lowFreq / fs
                let wh = 2.0 * Double.pi * highFreq / fs
                
                // Pre-warped frequencies
                let warpedLow = 2.0 * fs * tan(wl / 2.0)
                let warpedHigh = 2.0 * fs * tan(wh / 2.0)
                
                // Bandwidth and center frequency in warped domain
                let bw = warpedHigh - warpedLow
                let w0 = sqrt(warpedLow * warpedHigh)
                
                // For a 2nd-order Butterworth bandpass:
                // The analog prototype has a single complex pole pair at s = -1/√2 ± j/√2
                // For bandpass, we use the lowpass-to-bandpass transformation
                
                // Q factor for 2nd-order Butterworth is 1/√2
                let Q = w0 / bw
                
                // Analog bandpass transfer function coefficients
                // H(s) = (s/Q) / (s² + s/Q + 1) after normalization
                
                // Apply bilinear transform s = 2*fs*(z-1)/(z+1)
                // After substitution and simplification:
                let K = 2.0 * fs
                let K2 = K * K
                let w02 = w0 * w0
                let norm = K2 + K * w0 / Q + w02
                
                // Digital filter coefficients
                let b0 = Float((K * w0 / Q) / norm)
                let b1 = Float(0.0)  // Bandpass has zero at DC and Nyquist
                let b2 = Float(-b0)
                let a1 = Float((2.0 * (w02 - K2)) / norm)
                let a2 = Float((K2 - K * w0 / Q + w02) / norm)
                
                self.coefficients = FilterCoefficients(
                        b0: b0, b1: b1, b2: b2,
                        a1: a1, a2: a2
                )
                
                self.state = FilterState()
        }
        
        func process(_ input: [Float]) -> [Float] {
                var output = [Float](repeating: 0, count: input.count)
                
                for i in 0..<input.count {
                        output[i] = processSample(input[i])
                }
                
                return output
        }
        
        func processSample(_ x: Float) -> Float {
                // Transposed Direct Form II
                // y = b0*x + d1
                let y = coefficients.b0 * x + state.d1
                
                // Update delay states
                // d1_new = b1*x - a1*y + d2
                // d2_new = b2*x - a2*y
                let d1New = coefficients.b1 * x - coefficients.a1 * y + state.d2
                let d2New = coefficients.b2 * x - coefficients.a2 * y
                
                state.d1 = d1New
                state.d2 = d2New
                
                return y
        }
        
        func reset() {
                state.d1 = 0.0
                state.d2 = 0.0
        }
}



// MARK: - Filtered Circular Buffer (Redesigned)
class FilteredCircularBuffer {
        private let capacity: Int
        private let buffer: UnsafeMutableBufferPointer<Float>
        private var writeIndex = 0
        private var totalWritten = 0
        private let lock = NSLock()
        
        // Reference to audio processor
        weak var audioProcessor: AudioProcessor?
        
        // Tracking position in source
        private var lastReadPosition = 0
        
        // Position tracking for continuous reads (PLL)
        private var continuousReadPosition = 0
        
        // Filter state
        private var filter: ButterworthBandpassFilter?
        private var cachedMinFreq: Double = 0
        private var cachedMaxFreq: Double = 0
        let sampleRate: Double
        
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
                let filtered = newSamples//filter.process(newSamples)
                
                // Write filtered samples to our buffer
                writeSamples(filtered)
        }
        
        /// Get continuous samples since last read position (for PLL)
        /// Returns nil if buffer has overflowed (lost samples)
        func getContinuousSamples() -> [Float]? {
                lock.lock()
                defer { lock.unlock() }
                
                // Check if we've lost samples due to buffer overflow
                if totalWritten - continuousReadPosition > capacity {
                        // Buffer overflowed - reset position to current write position
                        // This allows PLL to re-acquire phase naturally
                        continuousReadPosition = totalWritten
                        return nil
                }
                
                // No new samples
                if continuousReadPosition >= totalWritten {
                        return []
                }
                
                // Calculate how many samples to return
                let samplesAvailable = totalWritten - continuousReadPosition
                let samplesToReturn = min(samplesAvailable, capacity)
                
                // Calculate read position in circular buffer
                let readStart = (writeIndex - (totalWritten - continuousReadPosition) + capacity) % capacity
                
                // Read samples
                var samples = [Float](repeating: 0, count: samplesToReturn)
                
                // Read in up to two chunks (handling wrap-around)
                let firstChunkSize = min(samplesToReturn, capacity - readStart)
                for i in 0..<firstChunkSize {
                        samples[i] = buffer[readStart + i]
                }
                
                if samplesToReturn > firstChunkSize {
                        let secondChunkSize = samplesToReturn - firstChunkSize
                        for i in 0..<secondChunkSize {
                                samples[firstChunkSize + i] = buffer[i]
                        }
                }
                
                // Update continuous read position
                continuousReadPosition = totalWritten
                
                return samples
        }
        
        /// Get samples since a specific position (alternative API)
        func getSamplesSince(position: Int) -> (samples: [Float], newPosition: Int)? {
                lock.lock()
                defer { lock.unlock() }
                
                // Check if we've lost samples due to buffer overflow
                if totalWritten - position > capacity {
                        // Buffer overflowed - return nil to indicate discontinuity
                        return nil
                }
                
                // No new samples
                if position >= totalWritten {
                        return ([], totalWritten)
                }
                
                // Calculate how many samples to return
                let samplesAvailable = totalWritten - position
                let samplesToReturn = min(samplesAvailable, capacity)
                
                // Calculate read position in circular buffer
                let readStart = (writeIndex - (totalWritten - position) + capacity) % capacity
                
                // Read samples
                var samples = [Float](repeating: 0, count: samplesToReturn)
                
                // Read in up to two chunks (handling wrap-around)
                let firstChunkSize = min(samplesToReturn, capacity - readStart)
                for i in 0..<firstChunkSize {
                        samples[i] = buffer[readStart + i]
                }
                
                if samplesToReturn > firstChunkSize {
                        let secondChunkSize = samplesToReturn - firstChunkSize
                        for i in 0..<secondChunkSize {
                                samples[firstChunkSize + i] = buffer[i]
                        }
                }
                
                return (samples, totalWritten)
        }
        
        /// Get latest filtered samples (for FFT - preserves existing behavior)
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
        
        /// Reset continuous read position (call this when starting PLL processing)
        func resetContinuousReadPosition() {
                lock.lock()
                defer { lock.unlock() }
                continuousReadPosition = totalWritten
        }
        
        /// Get current position for bookmarking
        func getCurrentPosition() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return totalWritten
        }
        
        /// Refilter entire buffer from raw source
        private func refilterFromSource() {
                guard let audioProcessor = audioProcessor,
                      let filter = filter else { return }
                
                // Get all raw samples
                let rawSamples = audioProcessor.getAllRawSamples()
                guard !rawSamples.isEmpty else { return }
                
                // Apply filter to all samples
                let filtered = rawSamples//filter.process(rawSamples)
                
                // Reset buffer and write all filtered samples
                writeIndex = 0
                totalWritten = 0
                continuousReadPosition = 0  // Reset continuous read position too
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
struct ANFDatum {
        let freq: Double
        let amp: Double
        let bandwidth: Double
        let convergenceRating: Double
}

struct StudyResult {
        let anfData: [ANFDatum]
        let filteredAudio: [Float]                   // Latest filtered audio window
        let filterBandwidth: (min: Double, max: Double)
        let timestamp: Date
        let processingTime: TimeInterval
}

final class Study: ObservableObject {
        // Core components (owned)
        private let audioProcessor: AudioProcessor
        private let store: TuningParameterStore
        private let filteredBuffer: FilteredCircularBuffer
        private var cascadedANFTracker: CascadedANFTracker
        private let fftProcessor: FFTProcessor
        private var currentTargetFrequency: Double
        
        // Processing queue
        private let studyQueue = DispatchQueue(label: "com.app.study", qos: .userInitiated)
        
        // State
        var isRunning = false
        private let updateRate: Double = 60.0  // Hz
        
        // Cached results
        @Published var latestResult: StudyResult?
        @Published var currentANFData: [ANFDatum] = []
        @Published var currentFilteredAudio: [Float] = []
        @Published var isProcessing = false
        
        // FFT spectrum data
        @Published var targetOriginalSpectrum: [Float] = []
        @Published var targetFrequencies: [Float] = []
        var binMapper: BinMapper?
        
        init(store: TuningParameterStore) {
                self.store = store
                self.currentTargetFrequency = Double(store.targetFrequency())
                self.currentANFData = []
                
                self.audioProcessor = AudioProcessor(store: store)
                self.filteredBuffer = FilteredCircularBuffer(
                        capacity: store.circularBufferSize,
                        sampleRate: store.audioSampleRate,
                        audioProcessor: self.audioProcessor
                )
                
                // Initialize cascaded ANF tracker
                self.cascadedANFTracker = CascadedANFTracker(
                        buffer: self.filteredBuffer,
                        parameterStore: self.store,
                        frequencyWindow: store.anfFrequencyWindow(),  // Renamed from pllFrequencyWindow
                        bandwidth: 2.0,  // Hz - configurable
                        numTrackers: 1   // Number of parallel ANFs
                )
                
                // Initialize FFT processor
                self.fftProcessor = FFTProcessor(fftSize: store.fftSize)
                self.fftProcessor.initializeFrequencies(sampleRate: Float(store.audioSampleRate))
                
                // Initialize BinMapper
                self.binMapper = BinMapper(
                        store: store,
                        halfSize: store.fftSize / 2
                )
        }
        
        // MARK: - Start / Stop
        
        func start() {
                guard !self.isRunning else { return }
                print("▶️ audioProcessor.start() called")
                
                self.filteredBuffer.updateFilter(
                        minFreq: self.store.currentMinFreq,
                        maxFreq: self.store.currentMaxFreq
                )
                
                // Start audio processor
                self.audioProcessor.start()
                
                self.isRunning = true
                
                // Start processing loop
                self.studyQueue.async { [weak self] in
                        self?.processingLoop()
                }
        }
        
        func stop() {
                self.isRunning = false
                self.audioProcessor.stop()
        }
        
        // MARK: - Main Processing Loop
        
        private func processingLoop() {
                while self.isRunning {
                        autoreleasepool {
                                self.perform()
                        }
                        Thread.sleep(forTimeInterval: 1.0 / self.updateRate)
                }
        }
        
        // MARK: - Main Analysis Method
        
        func perform() {
                DispatchQueue.main.async { [weak self] in
                        self?.isProcessing = true
                }
                
                let startTime = CFAbsoluteTimeGetCurrent()
                
                // Update filter based on current frequency range
                self.filteredBuffer.updateFilter(
                        minFreq: self.store.currentMinFreq,
                        maxFreq: self.store.currentMaxFreq,
                        refilter: true
                )
                
                self.filteredBuffer.updateFromAudioProcessor()
                
                // Get latest samples for UI display (not for ANF processing)
                guard let displaySamples = self.filteredBuffer.getLatest(size: min(4096, self.store.circularBufferSize)) else {
                        DispatchQueue.main.async { [weak self] in
                                self?.isProcessing = false
                        }
                        return
                }
                
                // Get fixed window for FFT (separate from ANF processing)
                guard let fftWindow = self.filteredBuffer.getLatest(size: self.store.fftSize) else {
                        DispatchQueue.main.async { [weak self] in
                                self?.isProcessing = false
                        }
                        return // Not enough data yet
                }
                
                // Perform FFT on fixed window (no windowing)
                fftWindow.withUnsafeBufferPointer { audioPtr in
                        self.fftProcessor.performFFT(input: audioPtr.baseAddress!, applyWindow: false)
                }
                
                // Convert to dB scale
                self.fftProcessor.convertMagnitudesToDB()
                
                // Copy FFT results
                let spectrumData = Array(UnsafeBufferPointer(
                        start: self.fftProcessor.magnitudeBuffer,
                        count: self.fftProcessor.halfSize
                ))
                let frequencyData = Array(UnsafeBufferPointer(
                        start: self.fftProcessor.frequencyBuffer,
                        count: self.fftProcessor.halfSize
                ))
                
                // Run cascaded ANF tracking
                let anfResults = self.cascadedANFTracker.track()
                print("\n📊 Study.perform: Got \(anfResults.count) ANF results")

                
                // Create result
                let result = StudyResult(
                        anfData: anfResults,
                        filteredAudio: displaySamples,
                        filterBandwidth: (min: self.store.currentMinFreq, max: self.store.currentMaxFreq),
                        timestamp: Date(),
                        processingTime: CFAbsoluteTimeGetCurrent() - startTime
                )
                
                let targ = Double(self.store.targetFrequency())
                
                // Update published properties on main queue
                DispatchQueue.main.async { [weak self] () -> Void in
                        print("  📱 Updating UI with \(anfResults.count) ANF results")
                        self?.currentANFData = anfResults
                        self?.latestResult = result
                        self?.currentFilteredAudio = displaySamples
                        self?.targetOriginalSpectrum = spectrumData
                        self?.targetFrequencies = frequencyData
                        self?.isProcessing = false
                        
                }
        }
        
        // MARK: - Public Query Methods
        
        func getLatestANFData() -> [ANFDatum] {
                return self.currentANFData
        }
        
        func getLatestFilteredAudio() -> [Float] {
                return self.currentFilteredAudio
        }
        
        func getFilterBandwidth() -> (min: Double, max: Double) {
                return (min: self.store.currentMinFreq, max: self.store.currentMaxFreq)
        }
        
        // MARK: - Filter Management
        
        func refilterAll() {
                self.filteredBuffer.updateFilter(
                        minFreq: self.store.currentMinFreq,
                        maxFreq: self.store.currentMaxFreq,
                        refilter: true
                )
        }
        
        // MARK: - ANF Configuration Updates
        
        func updateANFConfiguration() {
                // Reset tracker with new parameters when configuration changes
                self.cascadedANFTracker.reset()
        }
}
