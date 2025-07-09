import Foundation
import Accelerate

class ToneEKF {
        // Configuration parameters
        let M: Int  // Number of tones to track
        let fs: Double  // Sampling frequency
        let dt: Double  // Sample period
        let minSeparationHz: Double
        let R: Double  // Measurement noise variance
        let RPseudo: Double  // Pseudo-measurement noise variance
        let sigmaPhi: Double  // Phase process noise (radians/sample)
        let sigmaF: Double  // Frequency process noise (Hz/sample)
        let sigmaA: Double  // Amplitude process noise
        let covarianceJitter: Double
        
        // State variables
        let nStates: Int  // 3 * M (phase, freq, amplitude for each tone)
        let nTones: Int
        var x: [Double]  // State vector
        var P: [Double]  // Covariance matrix (stored in column-major order)
        
        // Constant matrices
        let F: [Double]  // State transition matrix (column-major)
        let Q: [Double]  // Process noise covariance (column-major)
        let RMat: [Double]  // Measurement noise covariance 2x2 (column-major)
        
        var sampleCount: Int = 0
        
        // Working buffers for matrix operations
        private var workBuffer: [Double]
        private var work2Buffer: [Double]
        private var work3Buffer: [Double]
        
        init(M: Int, fs: Double,
             initialFreqs: [Double]? = nil,
             minSeparationHz: Double = 2.30e-03,
             R: Double = 1.1,                   // Lower measurement noise for cleaner audio
             RPseudo: Double = 1e-6,             // Keep tight for separation enforcement
             sigmaPhi: Double = 1.1,             // Was 29.4 - way too high for stable tones
             sigmaF: Double = 500.01,              // Allow for some frequency drift/vibrato
             sigmaA: Double = 1.1,               // Lower amplitude variation for stable tones
             covarianceJitter: Double = 1e-12) {
                
                self.M = M
                self.fs = fs
                self.dt = 1.0 / fs
                self.minSeparationHz = minSeparationHz
                self.R = R
                self.RPseudo = RPseudo
                self.sigmaPhi = sigmaPhi
                self.sigmaF = sigmaF
                self.sigmaA = sigmaA
                self.covarianceJitter = covarianceJitter
                
                self.nStates = 3 * M
                self.nTones = M
                
                // Initialize state and covariance
                self.x = Array(repeating: 0.0, count: nStates)
                self.P = Array(repeating: 0.0, count: nStates * nStates)
                
                // Initialize working buffers
                let maxSize = nStates * nStates
                self.workBuffer = Array(repeating: 0.0, count: maxSize)
                self.work2Buffer = Array(repeating: 0.0, count: maxSize)
                self.work3Buffer = Array(repeating: 0.0, count: maxSize)
                
                // Build constant matrices
                self.F = ToneEKF.buildTransitionMatrix(nStates: nStates, nTones: nTones, dt: dt)
                self.Q = ToneEKF.buildProcessNoise(nStates: nStates, nTones: nTones,
                                                   sigmaPhi: sigmaPhi, sigmaF: sigmaF,
                                                   sigmaA: sigmaA, dt: dt)
                self.RMat = [R, 0, 0, R]  // Column-major order
                
                // Initialize state
                if let freqs = initialFreqs, freqs.count >= 2 {
                        let adjustedFreqs = adjustInitialFrequencies(freqs)
                        initializeState(initialFreqs: adjustedFreqs)
                } else {
                        initializeState(initialFreqs: initialFreqs)
                }
        }
        
        private func adjustInitialFrequencies(_ initialFreqs: [Double]) -> [Double] {
                var freqs = initialFreqs
                let targetSeparation = 1.0 * minSeparationHz
                
                // Sort frequencies
                let sortedIndices = freqs.indices.sorted { freqs[$0] < freqs[$1] }
                var sortedFreqs = sortedIndices.map { freqs[$0] }
                
                // Adjust frequencies pairwise
                for i in 1..<sortedFreqs.count {
                        let separation = sortedFreqs[i] - sortedFreqs[i-1]
                        if separation < targetSeparation {
                                let pushAmount = (targetSeparation - separation) * 0.7
                                sortedFreqs[i] += pushAmount
                                if sortedFreqs[i-1] - pushAmount > 0 {
                                        sortedFreqs[i-1] -= pushAmount
                                } else {
                                        sortedFreqs[i] += pushAmount
                                }
                        }
                }
                
                // Restore original order
                var adjustedFreqs = Array(repeating: 0.0, count: freqs.count)
                for (idx, sortedIdx) in sortedIndices.enumerated() {
                        adjustedFreqs[sortedIdx] = sortedFreqs[idx]
                }
                
                return adjustedFreqs
        }
        
        private func initializeState(initialFreqs: [Double]?) {
                var freqs: [Double]
                
                if let initialFreqs = initialFreqs {
                        guard initialFreqs.count == nTones else {
                                fatalError("initialFreqs must have length \(nTones)")
                        }
                        freqs = initialFreqs.sorted()
                } else {
                        // Default: evenly spaced around 0 Hz
                        freqs = []
                        if nTones == 1 {
                                freqs = [0.0]
                        } else {
                                let startFreq = -Double(nTones - 1) * minSeparationHz / 2
                                for i in 0..<nTones {
                                        freqs.append(startFreq + Double(i) * minSeparationHz)
                                }
                        }
                }
                
                // Set initial state
                for i in 0..<nTones {
                        let idx = 3 * i
                        x[idx] = 0.0  // phase
                        x[idx + 1] = freqs[i]  // frequency
                        x[idx + 2] = 1.0  // amplitude
                }
                
                // Initialize covariance matrix (diagonal)
                P.withUnsafeMutableBufferPointer { buffer in
                        guard let ptr = buffer.baseAddress else { return }
                        vDSP_vclrD(ptr,
                                   1,
                                   vDSP_Length(nStates * nStates))
                }
                for i in 0..<nTones {
                        let idx = 3 * i
                        P[idx * nStates + idx] = 1.0  // phase variance
                        P[(idx + 1) * nStates + (idx + 1)] = 1e-6  // frequency variance
                        P[(idx + 2) * nStates + (idx + 2)] = 1.0  // amplitude variance
                }
        }
        
        private static func buildTransitionMatrix(nStates: Int, nTones: Int, dt: Double) -> [Double] {
                var F = Array(repeating: 0.0, count: nStates * nStates)
                
                // Identity matrix
                for i in 0..<nStates {
                        F[i * nStates + i] = 1.0
                }
                
                // Phase depends on frequency: F[phase_idx, freq_idx] = 2*pi*dt
                for i in 0..<nTones {
                        let phaseIdx = 3 * i
                        let freqIdx = phaseIdx + 1
                        F[freqIdx * nStates + phaseIdx] = 2 * .pi * dt  // Column-major
                }
                
                return F
        }
        
        private static func buildProcessNoise(nStates: Int, nTones: Int,
                                              sigmaPhi: Double, sigmaF: Double,
                                              sigmaA: Double, dt: Double) -> [Double] {
                let varPhi = sigmaPhi * sigmaPhi * dt
                let varF = sigmaF * sigmaF * dt
                let varA = sigmaA * sigmaA * dt
                
                var Q = Array(repeating: 0.0, count: nStates * nStates)
                
                for i in 0..<nTones {
                        let idx = 3 * i
                        Q[idx * nStates + idx] = varPhi
                        Q[(idx + 1) * nStates + (idx + 1)] = varF
                        Q[(idx + 2) * nStates + (idx + 2)] = varA
                }
                
                return Q
        }
        
        func update(i: Double, q: Double) {
                let y = DSPDoubleComplex(real: i, imag: q)
                
                // Prediction step
                predict()
                
                // Measurement update
                measurementUpdate(y: y)
                
                // Apply separation constraint
                separationPseudoMeasurements()
                
                // Enforce constraints
                enforceConstraints()
                
                // Wrap phases
                wrapPhases()
                
                // Enforce covariance properties
                enforceCovarianceProperties()
                
                sampleCount += 1
        }
        
        private func predict() {
                // State prediction: x = F * x
                var xNew = Array(repeating: 0.0, count: nStates)
                cblas_dgemv(CblasColMajor, CblasNoTrans,
                            Int(nStates), Int(nStates),
                            1.0, F, Int(nStates),
                            x, 1,
                            0.0, &xNew, 1)
                x = xNew
                
                // Covariance prediction: P = F * P * F' + Q
                // First: work = F * P
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans,
                            Int(nStates), Int(nStates), Int(nStates),
                            1.0, F, Int(nStates),
                            P, Int(nStates),
                            0.0, &workBuffer, Int(nStates))
                
                // Second: P = work * F' + Q
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasTrans,
                            Int(nStates), Int(nStates), Int(nStates),
                            1.0, workBuffer, Int(nStates),
                            F, Int(nStates),
                            0.0, &P, Int(nStates))
                
                // Add Q
                vDSP_vaddD(P, 1, Q, 1, &P, 1, vDSP_Length(nStates * nStates))
        }
        
        private func measurementUpdate(y: DSPDoubleComplex) {
                // Compute measurement Jacobian H (2 x nStates)
                var H = Array(repeating: 0.0, count: 2 * nStates)
                computeMeasurementJacobian(H: &H)
                
                // Predicted measurement (sum of all tones)
                var yPred = DSPDoubleComplex(real: 0, imag: 0)
                for toneIdx in 0..<nTones {
                        let idx = 3 * toneIdx
                        let amplitude = x[idx + 2]
                        let phase = x[idx]
                        yPred.real += amplitude * cos(phase)
                        yPred.imag += amplitude * sin(phase)
                }
                
                // Innovation
                let innovation = [y.real - yPred.real, y.imag - yPred.imag]
                
                // Innovation covariance: S = H * P * H' + R (2x2 matrix)
                var HP = Array(repeating: 0.0, count: 2 * nStates)
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans,
                            2, Int(nStates), Int(nStates),
                            1.0, H, 2,
                            P, Int(nStates),
                            0.0, &HP, 2)
                
                var S = Array(repeating: 0.0, count: 4)
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasTrans,
                            2, 2, Int(nStates),
                            1.0, HP, 2,
                            H, 2,
                            0.0, &S, 2)
                
                // Add R
                vDSP_vaddD(S, 1, RMat, 1, &S, 1, 4)
                
                // Invert S (2x2)
                var SInv = Array(repeating: 0.0, count: 4)
                invertMatrix2x2(S, &SInv)
                
                // Kalman gain: K = P * H' * inv(S)
                var PHt = Array(repeating: 0.0, count: nStates * 2)
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasTrans,
                            Int(nStates), 2, Int(nStates),
                            1.0, P, Int(nStates),
                            H, 2,
                            0.0, &PHt, Int(nStates))
                
                var K = Array(repeating: 0.0, count: nStates * 2)
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans,
                            Int(nStates), 2, 2,
                            1.0, PHt, Int(nStates),
                            SInv, 2,
                            0.0, &K, Int(nStates))
                
                // State update: x = x + K * innovation
                cblas_dgemv(CblasColMajor, CblasNoTrans,
                            Int(nStates), 2,
                            1.0, K, Int(nStates),
                            innovation, 1,
                            1.0, &x, 1)
                
                // Covariance update (Joseph form)
                // P = (I - K*H) * P * (I - K*H)' + K * R * K'
                
                // First compute I - K*H
                var IMinusKH = Array(repeating: 0.0, count: nStates * nStates)
                for i in 0..<nStates {
                        IMinusKH[i * nStates + i] = 1.0  // Identity
                }
                
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans,
                            Int(nStates), Int(nStates), 2,
                            -1.0, K, Int(nStates),
                            H, 2,
                            1.0, &IMinusKH, Int(nStates))
                
                // workBuffer = (I - K*H) * P
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans,
                            Int(nStates), Int(nStates), Int(nStates),
                            1.0, IMinusKH, Int(nStates),
                            P, Int(nStates),
                            0.0, &workBuffer, Int(nStates))
                
                // work2Buffer = workBuffer * (I - K*H)'
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasTrans,
                            Int(nStates), Int(nStates), Int(nStates),
                            1.0, workBuffer, Int(nStates),
                            IMinusKH, Int(nStates),
                            0.0, &work2Buffer, Int(nStates))
                
                // work3Buffer = K * R * K'
                var KR = Array(repeating: 0.0, count: nStates * 2)
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans,
                            Int(nStates), 2, 2,
                            1.0, K, Int(nStates),
                            RMat, 2,
                            0.0, &KR, Int(nStates))
                
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasTrans,
                            Int(nStates), Int(nStates), 2,
                            1.0, KR, Int(nStates),
                            K, Int(nStates),
                            0.0, &work3Buffer, Int(nStates))
                
                // P = work2Buffer + work3Buffer
                vDSP_vaddD(work2Buffer, 1, work3Buffer, 1, &P, 1, vDSP_Length(nStates * nStates))
        }
        
        private func computeMeasurementJacobian(H: inout [Double]) {
                // H is 2 x nStates, stored in column-major order
                H.withUnsafeMutableBufferPointer { buffer in
                        guard let ptr = buffer.baseAddress else { return }
                        vDSP_vclrD(ptr,
                                   1,
                                   vDSP_Length(2 * nStates))
                }
                
                for toneIdx in 0..<nTones {
                        let idx = 3 * toneIdx
                        let phiIdx = idx
                        let ampIdx = idx + 2
                        
                        let phi = x[phiIdx]
                        let amp = x[ampIdx]
                        
                        // Column-major storage
                        // Real part derivatives
                        H[phiIdx * 2] = -amp * sin(phi)      // d(Re)/dphi
                        H[ampIdx * 2] = cos(phi)             // d(Re)/dA
                        
                        // Imaginary part derivatives
                        H[phiIdx * 2 + 1] = amp * cos(phi)   // d(Im)/dphi
                        H[ampIdx * 2 + 1] = sin(phi)         // d(Im)/dA
                }
        }
        
        private func separationPseudoMeasurements() {
                for i in 0..<(nTones - 1) {
                        applySeparationConstraint(toneI: i, toneJ: i + 1)
                }
        }
        
        private func applySeparationConstraint(toneI: Int, toneJ: Int) {
                let fIIdx = 3 * toneI + 1
                let fJIdx = 3 * toneJ + 1
                
                let fSep = x[fJIdx] - x[fIIdx]
                
                if fSep < minSeparationHz {
                        // Pseudo measurement Jacobian
                        var hPseudo = Array(repeating: 0.0, count: nStates)
                        hPseudo[fIIdx] = -1
                        hPseudo[fJIdx] = 1
                        
                        let desiredSep = minSeparationHz
                        let innovation = desiredSep - fSep
                        
                        // Innovation variance: s = h' * P * h + R_pseudo
                        var Ph = Array(repeating: 0.0, count: nStates)
                        cblas_dgemv(CblasColMajor, CblasNoTrans,
                                    Int(nStates), Int(nStates),
                                    1.0, P, Int(nStates),
                                    hPseudo, 1,
                                    0.0, &Ph, 1)
                        
                        var sPseudo = cblas_ddot(Int(nStates), hPseudo, 1, Ph, 1) + RPseudo
                        sPseudo = max(sPseudo, 1e-10 * trace() / Double(nStates))
                        
                        // Kalman gain: k = P * h / s
                        var kPseudo = Ph
                        cblas_dscal(Int(nStates), 1.0 / sPseudo, &kPseudo, 1)
                        
                        // Update state: x = x + k * innovation
                        cblas_daxpy(Int(nStates), innovation, kPseudo, 1, &x, 1)
                        
                        // Update covariance (Joseph form)
                        // P = (I - k*h') * P * (I - k*h')' + R_pseudo * k * k'
                        
                        // Compute outer product k * h'
                        var khT = Array(repeating: 0.0, count: nStates * nStates)
                        cblas_dger(CblasColMajor, Int(nStates), Int(nStates),
                                   1.0, kPseudo, 1, hPseudo, 1,
                                   &khT, Int(nStates))
                        
                        // I - k*h'
                        var IMinusKH = Array(repeating: 0.0, count: nStates * nStates)
                        for i in 0..<nStates {
                                IMinusKH[i * nStates + i] = 1.0
                        }
                        vDSP_vsubD(khT, 1, IMinusKH, 1, &IMinusKH, 1, vDSP_Length(nStates * nStates))
                        
                        // workBuffer = (I - k*h') * P
                        cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans,
                                    Int(nStates), Int(nStates), Int(nStates),
                                    1.0, IMinusKH, Int(nStates),
                                    P, Int(nStates),
                                    0.0, &workBuffer, Int(nStates))
                        
                        // work2Buffer = workBuffer * (I - k*h')'
                        cblas_dgemm(CblasColMajor, CblasNoTrans, CblasTrans,
                                    Int(nStates), Int(nStates), Int(nStates),
                                    1.0, workBuffer, Int(nStates),
                                    IMinusKH, Int(nStates),
                                    0.0, &work2Buffer, Int(nStates))
                        
                        // work3Buffer = R_pseudo * k * k'
                        cblas_dger(CblasColMajor, Int(nStates), Int(nStates),
                                   RPseudo, kPseudo, 1, kPseudo, 1,
                                   &work3Buffer, Int(nStates))
                        
                        // P = work2Buffer + work3Buffer
                        vDSP_vaddD(work2Buffer, 1, work3Buffer, 1, &P, 1, vDSP_Length(nStates * nStates))
                }
        }
        
        private func enforceConstraints() {
                for toneIdx in 0..<nTones {
                        let ampIdx = 3 * toneIdx + 2
                        if x[ampIdx] < 0 {
                                x[ampIdx] = -x[ampIdx]
                                let phaseIdx = 3 * toneIdx
                                x[phaseIdx] += .pi
                        }
                }
        }
        
        private func wrapPhases() {
                for toneIdx in 0..<nTones {
                        let phaseIdx = 3 * toneIdx
                        x[phaseIdx] = atan2(sin(x[phaseIdx]), cos(x[phaseIdx]))
                }
        }
        
        private func enforceCovarianceProperties() {
                // Enforce symmetry: P = (P + P') / 2
                var PT = Array(repeating: 0.0, count: nStates * nStates)
                vDSP_mtransD(P, 1, &PT, 1, vDSP_Length(nStates), vDSP_Length(nStates))
                vDSP_vaddD(P, 1, PT, 1, &P, 1, vDSP_Length(nStates * nStates))
                var scale = 0.5
                vDSP_vsmulD(P, 1, &scale, &P, 1, vDSP_Length(nStates * nStates))
                
                // Add jitter for numerical stability
                for i in 0..<nStates {
                        P[i * nStates + i] += covarianceJitter
                }
        }
        
        private func trace() -> Double {
                var trace = 0.0
                for i in 0..<nStates {
                        trace += P[i * nStates + i]
                }
                return trace
        }
        
        private func invertMatrix2x2(_ A: [Double], _ AInv: inout [Double]) {
                // For 2x2 matrix in column-major order
                let det = A[0] * A[3] - A[1] * A[2]
                let invDet = 1.0 / (det + 1e-10)
                
                AInv[0] = A[3] * invDet
                AInv[1] = -A[1] * invDet
                AInv[2] = -A[2] * invDet
                AInv[3] = A[0] * invDet
        }
        
        func getState() -> [String: Any] {
                var frequencies = Array(repeating: 0.0, count: nTones)
                var amplitudes = Array(repeating: 0.0, count: nTones)
                var phases = Array(repeating: 0.0, count: nTones)
                
                for toneIdx in 0..<nTones {
                        let idx = 3 * toneIdx
                        phases[toneIdx] = x[idx]
                        frequencies[toneIdx] = x[idx + 1]
                        amplitudes[toneIdx] = x[idx + 2]
                }
                
                // Sort by frequency
                let sortIndices = frequencies.indices.sorted { frequencies[$0] < frequencies[$1] }
                
                // Create permutation for covariance matrix
                var perm: [Int] = []
                for i in sortIndices {
                        perm.append(contentsOf: [3*i, 3*i+1, 3*i+2])
                }
                
                // Reorder covariance matrix
                var pSorted = Array(repeating: 0.0, count: nStates * nStates)
                for i in 0..<nStates {
                        for j in 0..<nStates {
                                pSorted[j * nStates + i] = P[perm[j] * nStates + perm[i]]
                        }
                }
                
                return [
                        "freqs": sortIndices.map { frequencies[$0] },
                        "amplitudes": sortIndices.map { amplitudes[$0] },
                        "phases": sortIndices.map { phases[$0] },
                        "covariance": pSorted,
                        "sampleCount": sampleCount
                ]
        }
        
        func getStateUnsorted() -> [String: Any] {
                var frequencies = Array(repeating: 0.0, count: nTones)
                var amplitudes = Array(repeating: 0.0, count: nTones)
                var phases = Array(repeating: 0.0, count: nTones)
                
                for toneIdx in 0..<nTones {
                        let idx = 3 * toneIdx
                        phases[toneIdx] = x[idx]
                        frequencies[toneIdx] = x[idx + 1]
                        amplitudes[toneIdx] = x[idx + 2]
                }
                
                return [
                        "freqs": frequencies,
                        "amplitudes": amplitudes,
                        "phases": phases,
                        "covariance": Array(P),  // Copy the array
                        "stateVector": Array(x),
                        "sampleCount": sampleCount
                ]
        }
        
        func getInnovationStats(y: DSPDoubleComplex) -> [String: Any] {
                var H = Array(repeating: 0.0, count: 2 * nStates)
                computeMeasurementJacobian(H: &H)
                
                var yPred = DSPDoubleComplex(real: 0, imag: 0)
                for toneIdx in 0..<nTones {
                        let idx = 3 * toneIdx
                        let amplitude = x[idx + 2]
                        let phase = x[idx]
                        yPred.real += amplitude * cos(phase)
                        yPred.imag += amplitude * sin(phase)
                }
                
                let innovation = [y.real - yPred.real, y.imag - yPred.imag]
                
                // S = H * P * H' + R
                var HP = Array(repeating: 0.0, count: 2 * nStates)
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans,
                            2, Int(nStates), Int(nStates),
                            1.0, H, 2,
                            P, Int(nStates),
                            0.0, &HP, 2)
                
                var S = Array(repeating: 0.0, count: 4)
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasTrans,
                            2, 2, Int(nStates),
                            1.0, HP, 2,
                            H, 2,
                            0.0, &S, 2)
                
                vDSP_vaddD(S, 1, RMat, 1, &S, 1, 4)
                
                return [
                        "innovation": innovation,
                        "S": S,
                        "H": H,
                        "yPred": yPred
                ]
        }
        
        func getNoiseParameters() -> [String: Double] {
                return [
                        "M": Double(M),
                        "R": R,
                        "RPseudo": RPseudo,
                        "sigmaPhi": sigmaPhi,
                        "sigmaF": sigmaF,
                        "sigmaA": sigmaA,
                        "minSeparationHz": minSeparationHz,
                        "covarianceJitter": covarianceJitter
                ]
        }
}
