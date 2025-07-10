import Foundation
import Accelerate

class ToneIMMFilter {
        private let ekfFast: ToneEKF
        private let ekfSlow: ToneEKF
        
        private var muFast: Double = 0.5
        private var muSlow: Double = 0.5
        
        private let transitionProb: [[Double]]
        
        // Working buffers for IMM operations
        private var mixedXFast: [Double]
        private var mixedXSlow: [Double]
        private var mixedPFast: [Double]
        private var mixedPSlow: [Double]
        
        private var tempX: [Double]
        private var tempP: [Double]
        private var deltaX: [Double]
        private var deltaXOuter: [Double]
        
        private var work3Buffer: [Double]
        private var hasLoggedNoise = false
        private var frameCounter: Int = 0

        
        private let nStates: Int
        
        init(M: Int, fs: Double,
             initialFreqs: [Double]? = nil,
             minSeparationHz: Double = 2.30e-03,
             RFast: Double = 10.0,      // Higher measurement noise for fast convergence
             RSlow: Double = 1.1,       // Lower measurement noise for precise tracking
             RPseudo: Double = 1e-6,
             sigmaPhiFast: Double = 10.0,
             sigmaFFast: Double = 2000.0,
             sigmaAFast: Double = 10.0,
             sigmaPhiSlow: Double = 1.1,
             sigmaFSlow: Double = 500.0,
             sigmaASlow: Double = 1.1,
             covarianceJitter: Double = 1e-12,
             transitionProb: [[Double]] = [[0.95, 0.05], [0.05, 0.95]]) {
                
                self.nStates = 3 * M
                self.transitionProb = transitionProb
                
                hasLoggedNoise = true
                
                self.mixedXFast = Array(repeating: 0.0, count: nStates)
                self.mixedXSlow = Array(repeating: 0.0, count: nStates)
                self.mixedPFast = Array(repeating: 0.0, count: nStates * nStates)
                self.mixedPSlow = Array(repeating: 0.0, count: nStates * nStates)
                
                self.tempX = Array(repeating: 0.0, count: nStates)
                self.tempP = Array(repeating: 0.0, count: nStates * nStates)
                self.deltaX = Array(repeating: 0.0, count: nStates)
                self.deltaXOuter = Array(repeating: 0.0, count: nStates * nStates)
                self.work3Buffer = Array(repeating: 0.0, count: nStates * nStates)
                
                self.ekfFast = ToneEKF(M: M, fs: fs,
                                       initialFreqs: initialFreqs,
                                       minSeparationHz: minSeparationHz,
                                       R: RFast,
                                       RPseudo: RPseudo,
                                       sigmaPhi: sigmaPhiFast,
                                       sigmaF: sigmaFFast,
                                       sigmaA: sigmaAFast,
                                       covarianceJitter: covarianceJitter)
                
                self.ekfSlow = ToneEKF(M: M, fs: fs,
                                       initialFreqs: initialFreqs,
                                       minSeparationHz: minSeparationHz,
                                       R: RSlow,
                                       RPseudo: RPseudo,
                                       sigmaPhi: sigmaPhiSlow,
                                       sigmaF: sigmaFSlow,
                                       sigmaA: sigmaASlow,
                                       covarianceJitter: covarianceJitter)
        }
        

        func update(i: Double, q: Double) {
                let y = DSPDoubleComplex(real: i, imag: q)
                
                // Increment frame counter
                frameCounter += 1
                let shouldPrint = (frameCounter % 1000 == 0)
                
                // 1) On first call, print each EKF's noise settings (always, not modulo-gated)
                if !hasLoggedNoise {
                        let fastNoise = ekfFast.getNoiseParameters()
                        let slowNoise = ekfSlow.getNoiseParameters()
                        print("🔧 Fast noise parameters:", fastNoise)
                        print("🔧 Slow noise parameters:", slowNoise)
                        hasLoggedNoise = true
                }
                
                // 2) Mixing step
                performMixing()
                
                // 3) Parallel EKF updates
                ekfFast.x = mixedXFast
                ekfFast.P = mixedPFast
                ekfFast.update(i: i, q: q)
                
                ekfSlow.x = mixedXSlow
                ekfSlow.P = mixedPSlow
                ekfSlow.update(i: i, q: q)
                
                // 4) Post‐update covariances P
                if shouldPrint {
                        if let Pfast = ekfFast.getState()["P"] as? [Double],
                           let Pslow = ekfSlow.getState()["P"] as? [Double] {
                                print(String(format: "📈 Post‐update P_fast[0]=%.3e   P_slow[0]=%.3e",
                                             Pfast[0], Pslow[0]))
                        }
                        
                        // 5) Innovation stats (ν and S)
                        let statsF = ekfFast.getInnovationStats(y: y)
                        let statsS = ekfSlow.getInnovationStats(y: y)
                        if let νf = statsF["innovation"] as? [Double],
                           let Sf = statsF["S"]           as? [Double],
                           let νs = statsS["innovation"] as? [Double],
                           let Ss = statsS["S"]           as? [Double] {
                                print("🔍 Fast innovation ν=", νf, "   S=", Sf)
                                print("🔍 Slow innovation ν=", νs, "   S=", Ss)
                        }
                }
                
                // 6) Compute raw likelihoods
                let λ_fast = computeLikelihood(ekf: ekfFast, y: y)
                let λ_slow = computeLikelihood(ekf: ekfSlow, y: y)
                
                // 7) Update mode probabilities
                updateModeProbabilities(lambdaFast: λ_fast, lambdaSlow: λ_slow)
                
                // 8) Print likelihoods and final weights
                if shouldPrint {
                        print(String(format:
                                        "🔀 λ_fast=%.3e   λ_slow=%.3e   μ_fast=%.4f   μ_slow=%.4f",
                                     λ_fast, λ_slow, muFast, muSlow))
                }
                
                // 9) Combine estimates for return
                combineEstimates()
        }
        
        private func performMixing() {
                // Compute mixing probabilities
                let denom = [
                        transitionProb[0][0] * muFast + transitionProb[1][0] * muSlow,
                        transitionProb[0][1] * muFast + transitionProb[1][1] * muSlow
                ]
                
                let mu00 = transitionProb[0][0] * muFast / denom[0]
                let mu10 = transitionProb[1][0] * muSlow / denom[0]
                let mu01 = transitionProb[0][1] * muFast / denom[1]
                let mu11 = transitionProb[1][1] * muSlow / denom[1]
                
                // Mixed state for fast model
                vDSP_vclrD(&mixedXFast, 1, vDSP_Length(nStates))
                cblas_daxpy(nStates, mu00, ekfFast.x, 1, &mixedXFast, 1)
                cblas_daxpy(nStates, mu10, ekfSlow.x, 1, &mixedXFast, 1)
                
                // Mixed state for slow model
                vDSP_vclrD(&mixedXSlow, 1, vDSP_Length(nStates))
                cblas_daxpy(nStates, mu01, ekfFast.x, 1, &mixedXSlow, 1)
                cblas_daxpy(nStates, mu11, ekfSlow.x, 1, &mixedXSlow, 1)
                
                // Mixed covariance for fast model
                vDSP_vclrD(&mixedPFast, 1, vDSP_Length(nStates * nStates))
                
                // Fast contribution to fast mixed
                vDSP_vsubD(mixedXFast, 1, ekfFast.x, 1, &deltaX, 1, vDSP_Length(nStates))
                cblas_dger(CblasColMajor, nStates, nStates,
                           1.0, deltaX, 1, deltaX, 1,
                           &deltaXOuter, nStates)
                vDSP_vaddD(ekfFast.P, 1, deltaXOuter, 1, &tempP, 1, vDSP_Length(nStates * nStates))
                cblas_daxpy(nStates * nStates, mu00, tempP, 1, &mixedPFast, 1)
                
                // Slow contribution to fast mixed
                vDSP_vclrD(&deltaXOuter, 1, vDSP_Length(nStates * nStates))
                vDSP_vsubD(mixedXFast, 1, ekfSlow.x, 1, &deltaX, 1, vDSP_Length(nStates))
                cblas_dger(CblasColMajor, nStates, nStates,
                           1.0, deltaX, 1, deltaX, 1,
                           &deltaXOuter, nStates)
                vDSP_vaddD(ekfSlow.P, 1, deltaXOuter, 1, &tempP, 1, vDSP_Length(nStates * nStates))
                cblas_daxpy(nStates * nStates, mu10, tempP, 1, &mixedPFast, 1)
                
                // Mixed covariance for slow model
                vDSP_vclrD(&mixedPSlow, 1, vDSP_Length(nStates * nStates))
                
                // Fast contribution to slow mixed
                vDSP_vclrD(&deltaXOuter, 1, vDSP_Length(nStates * nStates))
                vDSP_vsubD(mixedXSlow, 1, ekfFast.x, 1, &deltaX, 1, vDSP_Length(nStates))
                cblas_dger(CblasColMajor, nStates, nStates,
                           1.0, deltaX, 1, deltaX, 1,
                           &deltaXOuter, nStates)
                vDSP_vaddD(ekfFast.P, 1, deltaXOuter, 1, &tempP, 1, vDSP_Length(nStates * nStates))
                cblas_daxpy(nStates * nStates, mu01, tempP, 1, &mixedPSlow, 1)
                
                // Slow contribution to slow mixed
                vDSP_vclrD(&deltaXOuter, 1, vDSP_Length(nStates * nStates))
                vDSP_vsubD(mixedXSlow, 1, ekfSlow.x, 1, &deltaX, 1, vDSP_Length(nStates))
                cblas_dger(CblasColMajor, nStates, nStates,
                           1.0, deltaX, 1, deltaX, 1,
                           &deltaXOuter, nStates)
                vDSP_vaddD(ekfSlow.P, 1, deltaXOuter, 1, &tempP, 1, vDSP_Length(nStates * nStates))
                cblas_daxpy(nStates * nStates, mu11, tempP, 1, &mixedPSlow, 1)
        }
        
        private func computeLikelihood(ekf: ToneEKF, y: DSPDoubleComplex) -> Double {
                let stats = ekf.getInnovationStats(y: y)
                guard let innovation = stats["innovation"] as? [Double],
                      let S = stats["S"] as? [Double] else {
                        return 1e-100
                }
                
                // Compute determinant of 2x2 S matrix
                let detS = S[0] * S[3] - S[1] * S[2]
                if detS <= 0 {
                        return 1e-100
                }
                
                // Invert S
                var SInv = [Double](repeating: 0.0, count: 4)
                let invDet = 1.0 / detS
                SInv[0] = S[3] * invDet
                SInv[1] = -S[1] * invDet
                SInv[2] = -S[2] * invDet
                SInv[3] = S[0] * invDet
                
                // Compute innovation' * inv(S) * innovation
                var temp = [0.0, 0.0]
                cblas_dgemv(CblasColMajor, CblasNoTrans,
                            2, 2,
                            1.0, SInv, 2,
                            innovation, 1,
                            0.0, &temp, 1)
                
                let quadForm = cblas_ddot(2, innovation, 1, temp, 1)
                
                // Use log-likelihood to avoid numerical issues with large R differences
                let logLikelihoodAdj = -0.5 * quadForm
                
                // 4') (optional) clamp for numeric safety
                let clampedLL = max(-10000, min(10000, logLikelihoodAdj))
                
                // 5') back to linear domain:
                return exp(clampedLL)
        }
        
        private func updateModeProbabilities(lambdaFast: Double, lambdaSlow: Double) {
                let cBar = lambdaFast * (transitionProb[0][0] * muFast + transitionProb[1][0] * muSlow) +
                lambdaSlow * (transitionProb[0][1] * muFast + transitionProb[1][1] * muSlow)
                
                if cBar > 0 {
                        let muFastNew = lambdaFast * (transitionProb[0][0] * muFast + transitionProb[1][0] * muSlow) / cBar
                        let muSlowNew = lambdaSlow * (transitionProb[0][1] * muFast + transitionProb[1][1] * muSlow) / cBar
                        
                        muFast = muFastNew
                        muSlow = muSlowNew
                }
        }
        
        private func combineEstimates() {
                // Combined state
                vDSP_vclrD(&tempX, 1, vDSP_Length(nStates))
                cblas_daxpy(nStates, muFast, ekfFast.x, 1, &tempX, 1)
                cblas_daxpy(nStates, muSlow, ekfSlow.x, 1, &tempX, 1)
                
                // Combined covariance
                vDSP_vclrD(&tempP, 1, vDSP_Length(nStates * nStates))
                
                // Fast contribution
                vDSP_vsubD(tempX, 1, ekfFast.x, 1, &deltaX, 1, vDSP_Length(nStates))
                cblas_dger(CblasColMajor, nStates, nStates,
                           1.0, deltaX, 1, deltaX, 1,
                           &deltaXOuter, nStates)
                vDSP_vaddD(ekfFast.P, 1, deltaXOuter, 1, &work3Buffer, 1, vDSP_Length(nStates * nStates))
                cblas_daxpy(nStates * nStates, muFast, work3Buffer, 1, &tempP, 1)
                
                // Slow contribution
                vDSP_vclrD(&deltaXOuter, 1, vDSP_Length(nStates * nStates))
                vDSP_vsubD(tempX, 1, ekfSlow.x, 1, &deltaX, 1, vDSP_Length(nStates))
                cblas_dger(CblasColMajor, nStates, nStates,
                           1.0, deltaX, 1, deltaX, 1,
                           &deltaXOuter, nStates)
                vDSP_vaddD(ekfSlow.P, 1, deltaXOuter, 1, &work3Buffer, 1, vDSP_Length(nStates * nStates))
                cblas_daxpy(nStates * nStates, muSlow, work3Buffer, 1, &tempP, 1)
                
                // Copy results back
                ekfFast.x = tempX
                ekfFast.P = tempP
        }
        
        func getState() -> [String: Any] {
                var state = ekfFast.getState()
                state["muFast"] = muFast
                state["muSlow"] = muSlow
                
                // Add this logging temporarily
                if muSlow > 0.999 {
                        print("🐌 SLOW MODE: \(String(format: "%.3f", muSlow))")
                } else if muFast > 0.999 {
                        print("🏃 FAST MODE: \(String(format: "%.3f", muFast))")
                } else {
                        print("🤷 MIXED: fast=\(String(format: "%.3f", muFast)) slow=\(String(format: "%.3f", muSlow))")
                }
                
                return state
        }
        
        func getStateUnsorted() -> [String: Any] {
                var state = ekfFast.getStateUnsorted()
                state["muFast"] = muFast
                state["muSlow"] = muSlow
                return state
        }
        
        func getNoiseParameters() -> [String: Any] {
                let fastParams = ekfFast.getNoiseParameters()
                let slowParams = ekfSlow.getNoiseParameters()
                
                return [
                        "fast": fastParams,
                        "slow": slowParams,
                        "transitionProb": transitionProb,
                        "muFast": muFast,
                        "muSlow": muSlow
                ]
        }
}
