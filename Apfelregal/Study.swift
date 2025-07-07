// Study.swift
import Foundation
import SwiftUICore
import Accelerate
import CoreML
import Combine

struct StudyResults {
        let logDecimatedSpectrum: [Double]
        let logDecimatedFrequencies: [Double]
        let trackedPeaks: [Double]
        
        let isBaseband: Bool
        let centerFrequency: Double
        let sampleRate: Double
        let filterBandwidth: (min: Double, max: Double)
        
        let frameNumber: Int
}

// Study.swift changes

final class Study: ObservableObject {
        // Core components
        private let audioStream: AudioStream
        private let store: TuningParameterStore
        private let fftProcessor: FFTProcessor
        private var frameCounter = 0
        
        // Preprocessing components
        private var preprocessor: StreamingPreprocessor?
        private var rawBuffer: CircularBuffer<Double>
        private var basebandBuffer: CircularBuffer<DSPDoubleComplex>?
        
        // Processing queue
        private let studyQueue = DispatchQueue(label: "com.app.study", qos: .userInitiated)
        
        // State
        var isRunning = false
        private let updateRate: Double = 60.0
        private let fftRate: Double = 30.0
        private var lastFFTTime: CFAbsoluteTime = 0
        
        // Bookmarks for continuous reading
        private var audioStreamBookmark: Int = 0
        private var preprocessorBookmark: Int = 0
        
        // Thread-safe results
        @Published var results: StudyResults?
        private let resultsLock = NSLock()
        private var resultsBuffer: StudyResults?
        
        // Internal FFT results
        private var fullSpectrum: [Double] = []
        private var fullFrequencies: [Double] = []
        
        // Combine subscriptions
        private var cancellables = Set<AnyCancellable>()
        
        init(store: TuningParameterStore) {
                self.store = store
                self.audioStream = AudioStream(store: store)
                self.rawBuffer = CircularBuffer<Double>(capacity: store.circularBufferSize)
                self.fftProcessor = FFTProcessor(fftSize: store.fftSize)
                
                setupSubscriptions()
        }
        
        private func setupSubscriptions() {
                Publishers.CombineLatest3(
                        store.$zoomState,
                        store.$targetNote,
                        store.$concertPitch
                )
                .sink { [weak self] _, _, _ in
                        self?.studyQueue.async {
                                self?.updatePreprocessor()
                        }
                }
                .store(in: &cancellables)
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
        
        private func perform() {
                let (audioSamples, newBookmark) = audioStream.readAsDouble(sinceBookmark: audioStreamBookmark)
                audioStreamBookmark = newBookmark
                
                guard !audioSamples.isEmpty else { return }
                
                _ = rawBuffer.write(Array(audioSamples))
                
                let currentTime = CFAbsoluteTimeGetCurrent()
                let timeSinceLastFFT = currentTime - lastFFTTime
                
                guard timeSinceLastFFT >= (1.0 / fftRate) else { return }
                
                lastFFTTime = currentTime
                
                processSignal()
        }
        
        // MARK: - Unified Processing
        
        private func processSignal() {
                if let preprocessor = preprocessor {
                        let (newSamples, newPreprocessorBookmark) = rawBuffer.read(sinceBookmark: preprocessorBookmark)
                        preprocessorBookmark = newPreprocessorBookmark
                        
                        if !newSamples.isEmpty {

                                let basebandSamples = preprocessor.process(samples: newSamples)
                                if !basebandSamples.isEmpty {
                                        basebandBuffer?.write(basebandSamples)
                                }
                        }
                }
                
                let spectrum: ArraySlice<Double>
                let frequencies: ArraySlice<Double>
                let isBaseband: Bool
                let centerFreq: Double
                let sampleRate: Double
                
                if store.zoomState == .targetFundamental {
                        guard let preprocessor = preprocessor,
                              let buffer = basebandBuffer else {
                                publishEmptyResults()
                                return
                        }
                        
                        let samplesNeeded = Int(1.0 * preprocessor.fsOut)
                        
                        let (fftSamples, _) = buffer.read(maxSize: samplesNeeded)
                        
                        guard !fftSamples.isEmpty else {
                                publishEmptyResults()
                                return
                        }
                        // In processSignal(), before calling fftProcessor.processBaseband:
                        let result = fftProcessor.processBaseband(
                                samples: fftSamples,
                                basebandFreq: preprocessor.fBaseband,
                                decimatedRate: preprocessor.fsOut,
                                applyWindow: true
                        )
                        
                        spectrum = result.spectrum
                        frequencies = result.frequencies
                        isBaseband = true
                        centerFreq = preprocessor.fBaseband
                        sampleRate = preprocessor.fsOut
                        
                } else {
                        let (samples, _) = rawBuffer.read(maxSize: store.fftSize)
                        guard !samples.isEmpty else {
                                publishEmptyResults()
                                return
                        }
                        
                        let result = fftProcessor.processFullSpectrum(
                                samples: samples,
                                sampleRate: store.audioSampleRate,
                                applyWindow: true
                        )
                        
                        spectrum = result.spectrum
                        frequencies = result.frequencies
                        isBaseband = false
                        centerFreq = 0
                        sampleRate = store.audioSampleRate
                }
                
                fullSpectrum = Array(spectrum)
                fullFrequencies = Array(frequencies)
                
                let binMapper = createBinMapper(
                        isBaseband: isBaseband,
                        sampleRate: sampleRate,
                        spectrumSize: spectrum.count
                )
                
                
                let logDecimatedSpectrum = binMapper.mapSpectrum(spectrum)
                let logDecimatedFrequencies = binMapper.frequencies
                        
                frameCounter += 1
                let results = StudyResults(
                        logDecimatedSpectrum: Array(logDecimatedSpectrum),
                        logDecimatedFrequencies: Array(logDecimatedFrequencies),
                        trackedPeaks: [],
                        isBaseband: isBaseband,
                        centerFrequency: centerFreq,
                        sampleRate: sampleRate,
                        filterBandwidth: isBaseband ?
                        (min: centerFreq - preprocessor!.bandwidth/2,
                         max: centerFreq + preprocessor!.bandwidth/2) :
                                (min: 0, max: store.audioSampleRate / 2),
                        frameNumber: frameCounter
                )
                
                publishResults(results)
        }
        
        // MARK: - Update Methods
        
        private func updatePreprocessor() {
                let basebandFreq = store.targetFrequency()
                
                let needsUpdate = preprocessor == nil ||
                abs(preprocessor!.fBaseband - basebandFreq) > 1.0
                
                if needsUpdate {
                        print("🔧 Creating preprocessor for \(basebandFreq) Hz")
                        preprocessor = StreamingPreprocessor(
                                fsOrig: store.audioSampleRate,
                                fBaseband: basebandFreq,
                                marginCents: 50,
                                attenDB: 30
                        )
                        
                        if let pp = preprocessor {
                                print("🔧 Preprocessor: decimation=\(pp.decimationFactor), fsOut=\(pp.fsOut), bandwidth=\(pp.bandwidth)")
                                
                                let decimatedBufferSize = Int(Double(store.circularBufferSize) / Double(pp.decimationFactor))
                                basebandBuffer = CircularBuffer<DSPDoubleComplex>(capacity: decimatedBufferSize)
                                
                                let (availableSamples, _) = rawBuffer.read()
                                print("🔧 Processing \(availableSamples.count) existing samples")
                                
                                if !availableSamples.isEmpty {
                                        let basebandSamples = pp.process(samples: availableSamples)
                                        if !basebandSamples.isEmpty {
                                                print("🔧 Pre-filled buffer with \(basebandSamples.count) baseband samples")
                                                basebandBuffer?.write(basebandSamples)
                                        }
                                }
                                
                                preprocessorBookmark = rawBuffer.getTotalWritten()
                        }
                }
        }
        private func createBinMapper(isBaseband: Bool, sampleRate: Double, spectrumSize: Int) -> BinMapper {
                let minFreq: Double
                let maxFreq: Double
                let useLog: Bool
                let heterodyneOffset: Double
                
                if store.zoomState == .targetFundamental && isBaseband, let pp = preprocessor {
                        let bandwidth = pp.bandwidth
                        minFreq = pp.fBaseband - bandwidth/2
                        maxFreq = pp.fBaseband + bandwidth/2
                        useLog = false
                        heterodyneOffset = pp.fBaseband
                        print("🗺️ BinMapper baseband: \(minFreq)-\(maxFreq) Hz, linear scale")
                } else {
                        minFreq = store.viewportMinFreq
                        maxFreq = store.viewportMaxFreq
                        useLog = store.useLogFrequencyScale && (maxFreq / minFreq) > 2.0
                        heterodyneOffset = 0
                        print("🗺️ BinMapper full: \(minFreq)-\(maxFreq) Hz, \(useLog ? "log" : "linear") scale")

                }
                
                return BinMapper(
                        binCount: store.displayBinCount,
                        halfSize: spectrumSize,
                        sampleRate: sampleRate,
                        useLogScale: useLog,
                        minFreq: minFreq,
                        maxFreq: maxFreq,
                        heterodyneOffset: heterodyneOffset
                )
        }

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
        private func publishEmptyResults() {
                frameCounter += 1
                let emptyResults = StudyResults(
                        logDecimatedSpectrum: [],
                        logDecimatedFrequencies: [],
                        trackedPeaks: [],
                        isBaseband: store.zoomState == .targetFundamental,
                        centerFrequency: store.targetFrequency(),
                        sampleRate: preprocessor?.fsOut ?? store.audioSampleRate,
                        filterBandwidth: (min: 0, max: 0),
                        frameNumber: frameCounter
                )
                publishResults(emptyResults)
        }
}
