import Foundation
import Accelerate

enum TrackingMode {
        case fast
        case slow
}

struct NoiseParams {
        let R: Double
        let RPseudo: Double
        let sigmaPhi: Double
        let sigmaF: Double
        let sigmaA: Double
        let covarianceJitter: Double
}

class DualModeEKF {
        private let fastEKF: ToneEKF
        private let slowEKF: ToneEKF
        private let fs: Double
        private let baseband: Double
        
        private var mode: TrackingMode = .fast
        private var innovationRateCentsPerSec: Double = 0.0
        private var fastFreqEMA: Double = 0.0
        private var lastSlowFreq: Double = 0.0
        
        private let alphaInnovation: Double = 0.9
        private let alphaFreq: Double = 0.9
        private let centsPerSecThreshold: Double = 1.0
        private let centsDifferenceThreshold: Double = 3.0
        
        init(fs: Double,
             baseband: Double,
             fastParams: NoiseParams,
             slowParams: NoiseParams,
             initialFreq: Double? = nil) {
                
                self.fs = fs
                self.baseband = baseband
                
                let initialFreqs = initialFreq.map { [$0] }
                
                self.fastEKF = ToneEKF(
                        M: 1,
                        fs: fs,
                        initialFreqs: initialFreqs,
                        minSeparationHz: 0.0,
                        R: fastParams.R,
                        RPseudo: fastParams.RPseudo,
                        sigmaPhi: fastParams.sigmaPhi,
                        sigmaF: fastParams.sigmaF,
                        sigmaA: fastParams.sigmaA,
                        covarianceJitter: fastParams.covarianceJitter
                )
                
                self.slowEKF = ToneEKF(
                        M: 1,
                        fs: fs,
                        initialFreqs: initialFreqs,
                        minSeparationHz: 0.0,
                        R: slowParams.R,
                        RPseudo: slowParams.RPseudo,
                        sigmaPhi: slowParams.sigmaPhi,
                        sigmaF: slowParams.sigmaF,
                        sigmaA: slowParams.sigmaA,
                        covarianceJitter: slowParams.covarianceJitter
                )
                
                if let freq = initialFreq {
                        fastFreqEMA = freq
                        lastSlowFreq = freq
                }
        }
        
        func update(i: Double, q: Double) -> [String: Any] {
                let y = DSPDoubleComplex(real: i, imag: q)
                
                let fastFreqBefore = fastEKF.x[1]
                let fastInnovationStats = fastEKF.getInnovationStats(y: y)
                fastEKF.update(i: i, q: q)
                
                slowEKF.update(i: i, q: q)
                
                updateTrackingMetrics(fastInnovationStats: fastInnovationStats)
                updateFrequencyEMA(fastFreq: fastEKF.x[1])
                
                checkModeTransition()
                
                return mode == .fast ? fastEKF.getState() : slowEKF.getState()
        }
        
        private func updateTrackingMetrics(fastInnovationStats: [String: Any]) {
                guard let innovation = fastInnovationStats["innovation"] as? [Double],
                      let H = fastInnovationStats["H"] as? [Double],
                      let S = fastInnovationStats["S"] as? [Double] else { return }
                
                var HP = Array(repeating: 0.0, count: 2 * 3)
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans,
                            2, 3, 3,
                            1.0, H, 2,
                            fastEKF.P, 3,
                            0.0, &HP, 2)
                
                var SInv = Array(repeating: 0.0, count: 4)
                invertMatrix2x2(S, &SInv)
                
                var K = Array(repeating: 0.0, count: 3 * 2)
                var PHt = Array(repeating: 0.0, count: 3 * 2)
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasTrans,
                            3, 2, 3,
                            1.0, fastEKF.P, 3,
                            H, 2,
                            0.0, &PHt, 3)
                
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans,
                            3, 2, 2,
                            1.0, PHt, 3,
                            SInv, 2,
                            0.0, &K, 3)
                
                var stateCorrection = Array(repeating: 0.0, count: 3)
                cblas_dgemv(CblasColMajor, CblasNoTrans,
                            3, 2,
                            1.0, K, 3,
                            innovation, 1,
                            0.0, &stateCorrection, 1)
                
                let freqInnovationHz = stateCorrection[1]
                let freqInnovationHzPerSample = abs(freqInnovationHz)
                let freqInnovationHzPerSec = freqInnovationHzPerSample * fs
                let centsPerHz = 1200.0 / log(2.0) / baseband
                let innovationCentsPerSec = freqInnovationHzPerSec * centsPerHz
                
                innovationRateCentsPerSec = alphaInnovation * innovationRateCentsPerSec +
                (1.0 - alphaInnovation) * innovationCentsPerSec
        }
        
        private func updateFrequencyEMA(fastFreq: Double) {
                fastFreqEMA = alphaFreq * fastFreqEMA + (1.0 - alphaFreq) * fastFreq
        }
        
        private func checkModeTransition() {
                switch mode {
                case .fast:
                        if innovationRateCentsPerSec < centsPerSecThreshold {
                                transitionToSlowMode()
                        }
                        
                case .slow:
                        let freqDiffCents = abs(fastFreqEMA - lastSlowFreq) * (1200.0 / log(2.0) / baseband)
                        if freqDiffCents > centsDifferenceThreshold {
                                mode = .fast
                        } else {
                                lastSlowFreq = slowEKF.x[1]
                        }
                }
        }
        
        private func transitionToSlowMode() {
                mode = .slow
                
                slowEKF.x = Array(fastEKF.x)
                
                let fastParams = fastEKF.getNoiseParameters()
                let slowParams = slowEKF.getNoiseParameters()
                
                let scaleFactorPhi = sqrt(slowParams["sigmaPhi"]! / fastParams["sigmaPhi"]!)
                let scaleFactorF = sqrt(slowParams["sigmaF"]! / fastParams["sigmaF"]!)
                let scaleFactorA = sqrt(slowParams["sigmaA"]! / fastParams["sigmaA"]!)
                
                var scaledP = Array(repeating: 0.0, count: 9)
                for i in 0..<3 {
                        for j in 0..<3 {
                                var scale: Double = 1.0
                                if i == 0 && j == 0 {
                                        scale = scaleFactorPhi * scaleFactorPhi
                                } else if i == 1 && j == 1 {
                                        scale = scaleFactorF * scaleFactorF
                                } else if i == 2 && j == 2 {
                                        scale = scaleFactorA * scaleFactorA
                                } else if (i == 0 && j == 1) || (i == 1 && j == 0) {
                                        scale = scaleFactorPhi * scaleFactorF
                                } else if (i == 0 && j == 2) || (i == 2 && j == 0) {
                                        scale = scaleFactorPhi * scaleFactorA
                                } else if (i == 1 && j == 2) || (i == 2 && j == 1) {
                                        scale = scaleFactorF * scaleFactorA
                                }
                                scaledP[j * 3 + i] = fastEKF.P[j * 3 + i] * scale
                        }
                }
                
                slowEKF.P = scaledP
                lastSlowFreq = slowEKF.x[1]
        }
        
        private func invertMatrix2x2(_ A: [Double], _ AInv: inout [Double]) {
                let det = A[0] * A[3] - A[1] * A[2]
                let invDet = 1.0 / (det + 1e-10)
                
                AInv[0] = A[3] * invDet
                AInv[1] = -A[1] * invDet
                AInv[2] = -A[2] * invDet
                AInv[3] = A[0] * invDet
        }
        
        func getMode() -> TrackingMode {
                return mode
        }
        
        func getStats() -> [String: Any] {
                return [
                        "mode": mode,
                        "innovationRateCentsPerSec": innovationRateCentsPerSec,
                        "fastFreqEMA": fastFreqEMA,
                        "lastSlowFreq": lastSlowFreq,
                        "fastState": fastEKF.getState(),
                        "slowState": slowEKF.getState()
                ]
        }
}
