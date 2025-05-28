import Foundation
import AVFoundation
import Accelerate
import Combine
class AudioProcessor: ObservableObject {
    public let config: SpectrumAnalyzerConfig

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private let bufferStage: CircularBufferStage
    private let windowingStage: WindowingStage
    private let fftStage: FFTStage
    private let magnitudeStage: MagnitudeStage

    private let renderBinningStage: FrequencyBinningStage
    private let smoothingStage: ExponentialSmoothingStage
    private let varianceStage: VarianceTrackingStage

    private let processingQueue = DispatchQueue(label: "audio.processing")
    private let lock = NSLock()

    @Published var spectrumData: [Float] = []
    @Published var frequencyData: [Float] = []

    private var updateTimer: Timer?

    init(config: SpectrumAnalyzerConfig) {
        self.config = config

        self.bufferStage = CircularBufferStage(
            fftSize: config.fftSize,
            hopSize: config.hopSize,
            maxWindows: 10  // Can still use this as max extraction size
        )

        self.windowingStage = WindowingStage(windowType: .blackmanHarris, size: config.fftSize)
        self.fftStage = FFTStage(fftSize: config.fftSize, sampleRate: config.sampleRate)
        self.magnitudeStage = MagnitudeStage()

        self.renderBinningStage = FrequencyBinningStage(
            outputBinCount: config.outputBinCount,
            useLogScale: config.useLogFrequencyScale,
            minFrequency: config.minFrequency,
            maxFrequency: config.maxFrequency
        )

        self.smoothingStage = ExponentialSmoothingStage(smoothingFactor: config.smoothingFactor)
        self.varianceStage = VarianceTrackingStage()

        self.spectrumData = Array(repeating: -80, count: config.outputBinCount)
        self.frequencyData = (0..<config.outputBinCount).map { _ in 0 }
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    func start() {
        guard let url = Bundle.main.url(forResource: "Test", withExtension: "mp3"),
              let audioFile = try? AVAudioFile(forReading: url)
        else {
            print("Failed to load audio")
            return
        }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)

        let tapSize = AVAudioFrameCount(1024)  // Independent of hopSize
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: tapSize, format: audioFile.processingFormat) { buffer, _ in
            self.handleAudioBuffer(buffer)
        }

        // Start timer-driven processing
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / config.updateRateHz, repeats: true) { _ in
            self.processingQueue.async {
                self.processBufferedAudio()
            }
        }

        do {
            try engine.start()
            playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
            playerNode.play()
        } catch {
            print("Engine failed to start: \(error)")
        }
    }

    func stop() {
        updateTimer?.invalidate()
        playerNode.stop()
        engine.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    // MARK: - Audio Input Handler

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

        bufferStage.write(samples)
    }

    // MARK: - Time-Driven Processing

    private func processBufferedAudio() {
        let windows = bufferStage.extractWindows(maxWindows: 4)
        guard !windows.isEmpty else { return }

        let windowed = windowingStage.process(windows)
        let spectrum = fftStage.process(windowed)
        let magnitudes = magnitudeStage.process(spectrum)

        let bins = renderBinningStage.process(magnitudes)
        let smoothed = smoothingStage.process(bins)
        //let _ = varianceStage.process(smoothed)  // Analysis side effect only

        let latest = smoothed.first

        DispatchQueue.main.async {
            self.spectrumData = latest?.magnitudes ?? []
            self.frequencyData = latest?.frequencies ?? []
        }
    }
}
