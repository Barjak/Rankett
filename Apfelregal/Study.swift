import Foundation
import SwiftUICore
import Accelerate
import CoreML

struct StudyResults {
        let logDecimatedSpectrum: [Double]
        let logDecimatedFrequencies: [Double]
        let trackedPeaks: [Double]
        
        // Processing parameters
        let isBaseband: Bool
        let centerFrequency: Double
        let sampleRate: Double
        let filterBandwidth: (min: Double, max: Double)
}

final class Study: ObservableObject {
        // Core components
        private let audioStream: AudioStream
        private let store: TuningParameterStore
        private let fftProcessor: FFTProcessor
        private let binMapper: BinMapper

        
        // Preprocessing components
        private var preprocessor: StreamingPreprocessor?
        private var rawBuffer: CircularBuffer<Double>
        private var basebandBuffer: CircularBuffer<DSPDoubleComplex>?
        
        // Processing queue
        private let studyQueue = DispatchQueue(label: "com.app.study", qos: .userInitiated)
        
        // State
        var isRunning = false
        private let updateRate: Double = 60.0  // Hz
        private let fftRate: Double = 30.0     // Hz
        private var lastFFTTime: CFAbsoluteTime = 0
        
        // Bookmarks for continuous reading
        private var audioStreamBookmark: Int = 0
        private var preprocessorBookmark: Int = 0
        
        // Thread-safe results
        @Published var results: StudyResults?
        private let resultsLock = NSLock()
        private var resultsBuffer: StudyResults?
        
        // Internal FFT results (not published)
        private var fullSpectrum: [Double] = []
        private var fullFrequencies: [Double] = []
        
        init(store: TuningParameterStore) {
                self.store = store
                self.audioStream = AudioStream(store: store)
                self.rawBuffer = CircularBuffer<Double>(capacity: store.circularBufferSize)
                self.fftProcessor = FFTProcessor(fftSize: store.fftSize)
                
                // Initialize BinMapper for log-decimation
                self.binMapper = BinMapper(
                        binCount: 80,
                        halfSize: store.fftSize / 2,
                        sampleRate: store.audioSampleRate,
                        useLogScale: true,
                        minFreq: store.viewportMinFreq,
                        maxFreq: store.viewportMaxFreq
                )
        }
        
        // MARK: - Start / Stop
        
        func start() {
                guard !self.isRunning else { return }
                
                updatePreprocessor()
                audioStream.start()
                isRunning = true
                
                studyQueue.async { [weak self] in
                        self?.processingLoop()
                }
        }
        
        func stop() {
                isRunning = false
                audioStream.stop()
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
        
        // MARK: - Main Analysis
        
        private func perform() {
                // Read new audio samples
                let (audioSamples, newBookmark) = audioStream.readAsDouble(sinceBookmark: audioStreamBookmark)
                audioStreamBookmark = newBookmark
                
                guard !audioSamples.isEmpty else { return }
                
                // Write to raw buffer
                _ = rawBuffer.write(Array(audioSamples))
                
                // Check if it's time for FFT
                let currentTime = CFAbsoluteTimeGetCurrent()
                let timeSinceLastFFT = currentTime - lastFFTTime
                
                guard timeSinceLastFFT >= (1.0 / fftRate) else { return }
                
                lastFFTTime = currentTime
                
                // Update preprocessor if settings changed
                updatePreprocessor()
                
                // Process based on mode
                if store.usePreprocessor, let preprocessor = preprocessor {
                        processBasebandMode(preprocessor: preprocessor)
                } else {
                        processFullSpectrumMode()
                }
        }
        
        // MARK: - Processing Modes
        
        private func processBasebandMode(preprocessor: StreamingPreprocessor) {
                // Get only new samples for preprocessor to maintain continuity
                let (newSamples, newPreprocessorBookmark) = rawBuffer.read(sinceBookmark: preprocessorBookmark)
                preprocessorBookmark = newPreprocessorBookmark
                
                guard !newSamples.isEmpty else { return }
                
                // Process through preprocessor
                let basebandSamples = preprocessor.process(samples: newSamples)
                
                guard !basebandSamples.isEmpty else { return }
                
                // Write to baseband buffer
                basebandBuffer?.write(basebandSamples)
                
                // Get recent samples for FFT
                let (fftSamples, _) = basebandBuffer?.read(maxSize: store.fftSize) ?? ([], 0)
                
                guard !fftSamples.isEmpty else { return }
                
                // Perform complex FFT on baseband data
                let (spectrum, frequencies) = fftProcessor.processBaseband(
                        samples: fftSamples,
                        basebandFreq: preprocessor.fBaseband,
                        decimatedRate: preprocessor.fsOut,
                        applyWindow: true
                )
                
                // Store full resolution internally
                fullSpectrum = Array(spectrum)
                fullFrequencies = Array(frequencies)
                
                // Create log-decimated spectrum
                let logDecimatedSpectrum = binMapper.mapSpectrum(spectrum)
                let logDecimatedFrequencies = binMapper.frequencies
                
                // Create results
                let results = StudyResults(
                        logDecimatedSpectrum: Array(logDecimatedSpectrum),
                        logDecimatedFrequencies: Array(logDecimatedFrequencies),
                        trackedPeaks: [],
                        isBaseband: true,
                        centerFrequency: preprocessor.fBaseband,
                        sampleRate: preprocessor.fsOut,
                        filterBandwidth: (min: store.viewportMinFreq, max: store.viewportMaxFreq)
                )
                
                publishResults(results)
        }
        
        private func processFullSpectrumMode() {
                // Get recent samples for FFT
                let (samples, _) = rawBuffer.read(maxSize: store.fftSize)
                
                guard !samples.isEmpty else { return }
                
                // Perform FFT on full spectrum
                let (spectrum, frequencies) = fftProcessor.processFullSpectrum(
                        samples: samples,
                        sampleRate: store.audioSampleRate,
                        applyWindow: true
                )
                
                // Store full resolution internally
                fullSpectrum = Array(spectrum)
                fullFrequencies = Array(frequencies)
                
                // Create log-decimated spectrum
                let logDecimatedSpectrum = binMapper.mapSpectrum(spectrum)
                let logDecimatedFrequencies = binMapper.frequencies
                
                // Create results
                let results = StudyResults(
                        logDecimatedSpectrum: Array(logDecimatedSpectrum),
                        logDecimatedFrequencies: Array(logDecimatedFrequencies),
                        trackedPeaks: [],
                        isBaseband: false,
                        centerFrequency: 0,
                        sampleRate: store.audioSampleRate,
                        filterBandwidth: (min: 0, max: store.audioSampleRate / 2)
                )
                
                publishResults(results)
        }
        
        // MARK: - Preprocessor Management
        
        private func updatePreprocessor() {
                if store.usePreprocessor {
                        let basebandFreq = store.targetNote.frequency(concertA: store.concertPitch)
                        
                        let needsUpdate = preprocessor == nil ||
                        abs(preprocessor!.fBaseband - basebandFreq) > 1.0
                        
                        if needsUpdate {
                                preprocessor = StreamingPreprocessor(
                                        fsOrig: store.audioSampleRate,
                                        fBaseband: basebandFreq,
                                        marginCents: 50,
                                        attenDB: 30
                                )
                                
                                if let pp = preprocessor {
                                        let decimatedBufferSize = Int(Double(store.circularBufferSize) / Double(pp.decimationFactor))
                                        basebandBuffer = CircularBuffer<DSPDoubleComplex>(capacity: decimatedBufferSize)
                                        preprocessorBookmark = rawBuffer.getTotalWritten()
                                }
                        }
                } else {
                        if preprocessor != nil {
                                preprocessor = nil
                                basebandBuffer = nil
                        }
                }
        }
        
        // MARK: - Thread-Safe Results Publishing
        
        private func publishResults(_ newResults: StudyResults) {
                resultsLock.lock()
                resultsBuffer = newResults
                resultsLock.unlock()
                
                DispatchQueue.main.async { [weak self] in
                        self?.resultsLock.lock()
                        self?.results = self?.resultsBuffer
                        self?.resultsLock.unlock()
                }
        }
}
