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

final class Study: ObservableObject {
        private let audioStream: AudioStream
        private let store: TuningParameterStore
        private let fullSpectrumFFT: FFTProcessor
        private let basebandFFT: FFTProcessor
        private var frameCounter = 0
        
        private var preprocessor: StreamingPreprocessor?
        private var rawDoublesBuffer: CircularBuffer<Double>
        private var basebandBuffer: CircularBuffer<DSPDoubleComplex>?
        
        private var dualModeEKF: DualModeEKF?
        
        private let studyQueue = DispatchQueue(label: "com.app.study", qos: .userInitiated)
        
        var isRunning = false
        private let updateRate: Double = 60.0
        private let fftRate: Double = 30.0
        private var lastFFTTime: CFAbsoluteTime = 0
        
        private var audioStreamBookmark: Int = 0
        private var preprocessorBookmark: Int = 0
        
        @Published var results: StudyResults?
        private let resultsLock = NSLock()
        private var resultsBuffer: StudyResults?
        
        private var binMapper: BinMapper
        
        private var cancellables = Set<AnyCancellable>()
        
        init(store: TuningParameterStore) {
                self.store = store
                self.audioStream = AudioStream(store: store)
                self.rawDoublesBuffer = CircularBuffer<Double>(capacity: store.circularBufferSize)
                self.fullSpectrumFFT = FFTProcessor(fftSize: store.fftSize)
                self.basebandFFT = FFTProcessor(fftSize: store.fftSize)
                
                self.binMapper = BinMapper(
                        binCount: store.displayBinCount,
                        halfSize: store.fftSize / 2,
                        sampleRate: store.audioSampleRate,
                        useLogScale: true,
                        minFreq: 20,
                        maxFreq: 20000,
                        heterodyneOffset: 0,
                        smoothingFactor: 0.0
                )
                
                setupSubscriptions()
        }
        
        private func setupSubscriptions() {
                Publishers.CombineLatest3(
                        store.$targetNote,
                        store.$concertPitch,
                        store.$targetPartial
                )
                .sink { [weak self] _, _, _ in
                        self?.studyQueue.async {
                                self?.updatePreprocessor()
                        }
                }
                .store(in: &cancellables)
        }
        
        func start() {
                guard !isRunning else { return }
                
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
        
        private func processingLoop() {
                while isRunning {
                        autoreleasepool {
                                perform()
                        }
                        Thread.sleep(forTimeInterval: 1.0 / updateRate)
                }
        }
        
        private func perform() {
                let (audioSamples, newBookmark) = audioStream.readAsDouble(from: .bookmark(audioStreamBookmark))
                audioStreamBookmark = newBookmark
                
                guard !audioSamples.isEmpty else { return }
                
                _ = rawDoublesBuffer.write(Array(audioSamples))
                
                let currentTime = CFAbsoluteTimeGetCurrent()
                let timeSinceLastFFT = currentTime - lastFFTTime
                
                guard timeSinceLastFFT >= (1.0 / fftRate) else { return }
                
                lastFFTTime = currentTime
                
                processSignal()
        }
        
        private func processSignal() {
                let targetFreq = store.targetFrequency()
                
                if preprocessor == nil || abs(preprocessor!.fBaseband - targetFreq) > 1.0 {
                        updatePreprocessor()
                }
                
                var basebandSamples: [DSPDoubleComplex] = []
                if let preprocessor = preprocessor {
                        let (newSamples, newPreprocessorBookmark) = rawDoublesBuffer.read(from: .bookmark(preprocessorBookmark))
                        preprocessorBookmark = newPreprocessorBookmark
                        
                        if !newSamples.isEmpty {
                                basebandSamples = preprocessor.process(samples: newSamples)
                                if !basebandSamples.isEmpty {
                                        basebandBuffer?.write(basebandSamples)
                                }
                        }
                }
                
                let (fullSamples, _) = rawDoublesBuffer.read(count: store.fftSize)
                let fullResult = fullSpectrumFFT.processFullSpectrum(
                        samples: fullSamples,
                        sampleRate: store.audioSampleRate,
                        applyWindow: true
                )
                
                var basebandResult: (spectrum: ArraySlice<Double>, frequencies: ArraySlice<Double>)?
                if let preprocessor = preprocessor, let buffer = basebandBuffer {
                        let samplesNeeded = Int(2.0 * preprocessor.fsOut)
                        let (fftSamples, _) = buffer.read(count: samplesNeeded)
                        
                        if !fftSamples.isEmpty {
                                basebandResult = basebandFFT.processBaseband(
                                        samples: fftSamples,
                                        basebandFreq: preprocessor.fBaseband,
                                        decimatedRate: preprocessor.fsOut,
                                        applyWindow: true
                                )
                        }
                }
                
                if let ekf = dualModeEKF, !basebandSamples.isEmpty {
                        for sample in basebandSamples {
                                _ = ekf.update(i: sample.real, q: sample.imag)
                        }
                }
                
                let displayBaseband = store.zoomState == .targetFundamental && basebandResult != nil
                updateBinMapper(displayBaseband: displayBaseband)
                
                let (primarySpectrum, primaryFrequencies, primaryIsBaseband, primarySampleRate) =
                displayBaseband ?
                (basebandResult!.spectrum, basebandResult!.frequencies, true, preprocessor!.fsOut) :
                (fullResult.spectrum, fullResult.frequencies, false, store.audioSampleRate)
                
                let logDecimatedSpectrum = binMapper.mapSpectrum(primarySpectrum)
                let logDecimatedFrequencies = binMapper.frequencies
                
                var trackedPeaks: [Double] = []
                if let ekf = dualModeEKF, let preprocessor = preprocessor {
                        let state = ekf.update(i: 0, q: 0)
                        if let frequencies = state["freqs"] as? [Double] {
                                trackedPeaks = frequencies.map { freq in
                                        preprocessor.fBaseband + freq
                                }
                        }
                }
                
                frameCounter += 1
                let results = StudyResults(
                        logDecimatedSpectrum: Array(logDecimatedSpectrum),
                        logDecimatedFrequencies: Array(logDecimatedFrequencies),
                        trackedPeaks: trackedPeaks,
                        isBaseband: primaryIsBaseband,
                        centerFrequency: displayBaseband ? preprocessor!.fBaseband : 0,
                        sampleRate: primarySampleRate,
                        filterBandwidth: displayBaseband && preprocessor != nil ?
                        (min: preprocessor!.fBaseband - preprocessor!.bandwidth/2,
                         max: preprocessor!.fBaseband + preprocessor!.bandwidth/2) :
                                (min: 0, max: store.audioSampleRate / 2),
                        frameNumber: frameCounter
                )
                
                publishResults(results)
        }
        
        private func updatePreprocessor() {
                let basebandFreq = store.targetFrequency()
                
                let needsUpdate = preprocessor == nil ||
                abs(preprocessor!.fBaseband - basebandFreq) > 1.0
                
                if needsUpdate {
                        preprocessor = StreamingPreprocessor(
                                fsOrig: store.audioSampleRate,
                                fBaseband: basebandFreq,
                                marginCents: store.targetBandwidth,
                                attenDB: 70
                        )
                        
                        if let pp = preprocessor {
                                let decimatedBufferSize = Int(Double(store.circularBufferSize) / Double(pp.decimationFactor))
                                basebandBuffer = CircularBuffer<DSPDoubleComplex>(capacity: decimatedBufferSize)
                                preprocessorBookmark = rawDoublesBuffer.getTotalWritten()
                                
                                let fastParams = NoiseParams(
                                        R: 0.001,
                                        RPseudo: 1e-6,
                                        sigmaPhi: 50.0,
                                        sigmaF: 10.001,
                                        sigmaA: 50.0,
                                        covarianceJitter: 1e-10
                                )
                                
                                let slowParams = NoiseParams(
                                        R: 10.0,
                                        RPseudo: 1e-6,
                                        sigmaPhi: 50.01,
                                        sigmaF: 10.0,
                                        sigmaA: 50.01,
                                        covarianceJitter: 1e-10
                                )
                                
                                dualModeEKF = DualModeEKF(
                                        fs: pp.fsOut,
                                        baseband: basebandFreq,
                                        fastParams: fastParams,
                                        slowParams: slowParams,
                                        initialFreq: 0.0
                                )
                        }
                }
        }
        
        private func updateBinMapper(displayBaseband: Bool) {
                if displayBaseband, let pp = preprocessor {
                        let bandwidth = pp.bandwidth
                        binMapper.remap(
                                minFreq: pp.fBaseband - bandwidth/2,
                                maxFreq: pp.fBaseband + bandwidth/2,
                                heterodyneOffset: pp.fBaseband,
                                sampleRate: pp.fsOut,
                                halfSize: store.fftSize,
                                useLogScale: false
                        )
                } else {
                        binMapper.remap(
                                minFreq: store.viewportMinFreq,
                                maxFreq: store.viewportMaxFreq,
                                heterodyneOffset: 0,
                                sampleRate: store.audioSampleRate,
                                halfSize: store.fftSize / 2,
                                useLogScale: true
                        )
                }
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
}
