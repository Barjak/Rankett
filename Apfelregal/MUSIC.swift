import Foundation
import Accelerate
import SwiftUI

/// Core MUSIC implementation for 1D frequency estimation with Harmonic Product
struct MUSIC {
        let store: TuningParameterStore
        let sourceCount: Int
        var freqGrid: [Double] = []     // Make it mutable and initially empty
        var snapshotMatrix: [DSPComplex] // flattened: M rows × N cols
        let subarrayLength: Int     // M
        let snapshotCount: Int      // N
        
        // Harmonic weights: [1, 1/4, 1/9, 1/16, 1/25]
        let harmonicWeights: [Double] = [1.0, 0.5, 0.3, 0.2, 0.2]
        let numHarmonics: Int = 5
        
        // Track the last bounds to avoid unnecessary updates
        private var lastMinFreq: Double = 0
        private var lastMaxFreq: Double = 0
        private var lastResolution: Double = 0
        
        // Cache for noise subspace (computed once per snapshot update)
        private var noiseSubspace: [DSPDoubleComplex]?
        private var noiseDim: Int = 0
        
        init(store: TuningParameterStore, sourceCount: Int, subarrayLength: Int, snapshotCount: Int) {
                self.store = store
                self.sourceCount = sourceCount
                self.subarrayLength = subarrayLength
                self.snapshotCount = snapshotCount
                self.snapshotMatrix = [DSPComplex](repeating: DSPComplex(), count: subarrayLength * snapshotCount)
                
                // Initialize with default frequency grid
                updateFrequencyGrid()
        }
        
        /// Update the frequency grid based on current frequency bounds from store
        mutating func updateFrequencyGrid() {
                // Only update if the bounds or resolution have changed
                if abs(store.currentMinFreq - lastMinFreq) < 0.01 &&
                        abs(store.currentMaxFreq - lastMaxFreq) < 0.01 &&
                        abs(store.resolutionMUSIC - lastResolution) < 0.5 {
                        return
                }
                
                lastMinFreq = store.currentMinFreq
                lastMaxFreq = store.currentMaxFreq
                lastResolution = store.resolutionMUSIC
                
                // Convert to normalized frequencies (radians/sample)
                let fs = store.audioSampleRate
                let omegaLow = 2.0 * Double.pi * store.currentMinFreq / fs
                let omegaHigh = 2.0 * Double.pi * store.currentMaxFreq / fs
                
                // Create logarithmic frequency grid
                let gridPoints = Int(store.resolutionMUSIC)
                freqGrid = []
                
                // Work in log space for even logarithmic spacing
                let logLow = log(omegaLow)
                let logHigh = log(omegaHigh)
                
                for i in 0..<gridPoints {
                        let logOmega = logLow + (logHigh - logLow) * Double(i) / Double(gridPoints - 1)
                        let omega = exp(logOmega)
                        freqGrid.append(omega)
                }
        }
        
        /// Update snapshot matrix from audio window
        mutating func updateSnapshotMatrix(audioWindow: [Float]) {
                let M = subarrayLength
                let maxSnapshots = audioWindow.count - M + 1
                let N = min(maxSnapshots, snapshotCount)
                
                // Fill snapshot matrix with overlapping segments
                let stride = max(1, maxSnapshots / N)
                for n in 0..<N {
                        let startIdx = n * stride
                        for m in 0..<M {
                                let idx = n * M + m
                                if startIdx + m < audioWindow.count {
                                        snapshotMatrix[idx] = DSPComplex(real: audioWindow[startIdx + m], imag: 0)
                                }
                        }
                }
                
                // Mark noise subspace as needing recomputation
                noiseSubspace = nil
        }
        
        /// Create standard steering vector for a single frequency
        func createSteeringVector(omega: Double) -> [DSPDoubleComplex] {
                let M = subarrayLength
                var steering = [DSPDoubleComplex](repeating: DSPDoubleComplex(), count: M)
                
                for m in 0..<M {
                        let phase = -omega * Double(m)
                        steering[m] = DSPDoubleComplex(real: cos(phase), imag: sin(phase))
                }
                
                return steering
        }
        
        /// Compute noise subspace if not already cached
        mutating func computeNoiseSubspace() {
                guard noiseSubspace == nil else { return }
                
                let M = subarrayLength
                let N = snapshotCount
                
                // 1) Covariance: R = (1/N) * X * X^H
                var R = [DSPComplex](repeating: DSPComplex(), count: M * M)
                
                // Use BLAS zgemm for complex matrix multiplication
                var alpha = DSPDoubleComplex(real: 1.0 / Double(N), imag: 0.0)
                var beta = DSPDoubleComplex(real: 0.0, imag: 0.0)
                
                // Convert to double precision for BLAS
                var X_double = [DSPDoubleComplex](repeating: DSPDoubleComplex(), count: M * N)
                for i in 0..<(M * N) {
                        X_double[i] = DSPDoubleComplex(real: Double(snapshotMatrix[i].real),
                                                       imag: Double(snapshotMatrix[i].imag))
                }
                
                var R_double = [DSPDoubleComplex](repeating: DSPDoubleComplex(), count: M * M)
                
                X_double.withUnsafeBufferPointer { Xptr in
                        R_double.withUnsafeMutableBufferPointer { Rptr in
                                withUnsafePointer(to: &alpha) { alphaPtr in
                                        withUnsafePointer(to: &beta) { betaPtr in
                                                // R = alpha * X * X^H + beta * R
                                                cblas_zgemm(
                                                        CblasColMajor,      // matrix storage order
                                                        CblasNoTrans,       // no transpose for X
                                                        CblasConjTrans,     // conjugate transpose for X
                                                        Int(M), Int(M), Int(N),  // dimensions
                                                        OpaquePointer(alphaPtr),        // scaling factor
                                                        OpaquePointer(Xptr.baseAddress),
                                                        Int(M),
                                                        OpaquePointer(Xptr.baseAddress),
                                                        Int(M),
                                                        OpaquePointer(betaPtr),         // scaling for C
                                                        OpaquePointer(Rptr.baseAddress),
                                                        Int(M)
                                                )
                                        }
                                }
                        }
                }
                
                // 2) Eigendecomposition using zheev_
                var jobz: Int8 = Int8(UnicodeScalar("V").value)  // Compute eigenvectors
                var uplo: Int8 = Int8(UnicodeScalar("U").value)  // Upper triangle
                var n_eig = Int(M)
                var lda_eig = Int(M)
                var info = Int(0)
                
                // Eigenvalues
                var w = [Double](repeating: 0, count: M)
                
                // Work arrays
                var lwork = Int(-1)
                var workQuery = DSPDoubleComplex()
                var rwork = [Double](repeating: 0, count: max(1, 3 * M - 2))
                
                // Use R_double for eigendecomposition
                var A = R_double
                
                // Query workspace size
                A.withUnsafeMutableBufferPointer { Aptr in
                        withUnsafeMutablePointer(to: &workQuery) { workPtr in
                                zheev_(
                                        &jobz, &uplo, &n_eig,
                                        OpaquePointer(Aptr.baseAddress), &lda_eig,
                                        &w,
                                        OpaquePointer(workPtr), &lwork,
                                        &rwork,
                                        &info
                                )
                        }
                }
                
                lwork = Int(workQuery.real)
                var work = [DSPDoubleComplex](repeating: DSPDoubleComplex(), count: lwork)
                
                // Perform eigendecomposition
                A.withUnsafeMutableBufferPointer { Aptr in
                        work.withUnsafeMutableBufferPointer { workPtr in
                                guard let aBase = Aptr.baseAddress,
                                      let workBase = workPtr.baseAddress else {
                                        fatalError("Failed to get buffer pointers")
                                }
                                
                                zheev_(
                                        &jobz, &uplo, &n_eig,
                                        OpaquePointer(aBase), &lda_eig,
                                        &w,
                                        OpaquePointer(workBase), &lwork,
                                        &rwork,
                                        &info
                                )
                        }
                }
                
                precondition(info == 0, "Eigendecomposition failed: \(info)")
                
                // 3) Build noise subspace from smallest eigenvalues
                noiseDim = M - sourceCount
                var noiseVecs_double = [DSPDoubleComplex](repeating: DSPDoubleComplex(), count: M * noiseDim)
                
                // Extract eigenvectors corresponding to smallest eigenvalues
                for k in 0..<noiseDim {
                        for i in 0..<M {
                                // Column-major storage: k-th column, i-th row
                                let idx = k * M + i
                                noiseVecs_double[idx] = A[idx]
                        }
                }
                
                // Cache the noise subspace
                self.noiseSubspace = noiseVecs_double
        }
        
        /// Compute single-frequency MUSIC pseudospectrum value
        func singleFrequencyPseudospectrum(omega: Double) -> Double {
                guard let noiseVecs_double = noiseSubspace else {
                        fatalError("Noise subspace not computed")
                }
                
                let M = subarrayLength
                let a = createSteeringVector(omega: omega)
                
                // Compute E_n^H * a using BLAS zgemv
                var temp_double = [DSPDoubleComplex](repeating: DSPDoubleComplex(), count: noiseDim)
                var alpha_mv = DSPDoubleComplex(real: 1.0, imag: 0.0)
                var beta_mv = DSPDoubleComplex(real: 0.0, imag: 0.0)
                
                noiseVecs_double.withUnsafeBufferPointer { Enptr in
                        a.withUnsafeBufferPointer { aptr in
                                temp_double.withUnsafeMutableBufferPointer { tempPtr in
                                        withUnsafePointer(to: &alpha_mv) { alphaPtr in
                                                withUnsafePointer(to: &beta_mv) { betaPtr in
                                                        // temp = alpha * E_n^H * a + beta * temp
                                                        cblas_zgemv(
                                                                CblasColMajor,      // matrix storage order
                                                                CblasConjTrans,     // conjugate transpose E_n
                                                                Int(M),           // rows of E_n
                                                                Int(noiseDim),    // columns of E_n
                                                                OpaquePointer(alphaPtr),         // scaling factor
                                                                OpaquePointer(Enptr.baseAddress),  // matrix E_n
                                                                Int(M),           // leading dimension
                                                                OpaquePointer(aptr.baseAddress),   // vector a
                                                                1,                  // increment for a
                                                                OpaquePointer(betaPtr),           // scaling for temp
                                                                OpaquePointer(tempPtr.baseAddress),// output vector
                                                                1                   // increment for temp
                                                        )
                                                }
                                        }
                                }
                        }
                }
                
                // Compute ||E_n^H * a||²
                var power: Double = 0.0
                for i in 0..<noiseDim {
                        power += temp_double[i].real * temp_double[i].real + temp_double[i].imag * temp_double[i].imag
                }
                
                return 1.0 / max(power, 1e-12)
        }
        
        /// Compute harmonic product pseudospectrum using log-likelihood approach
        mutating func pseudospectrum() -> [Double] {
                // Update grid if needed before computing spectrum
                updateFrequencyGrid()
                
                // Ensure noise subspace is computed
                computeNoiseSubspace()
                
                // For each frequency in the grid, compute harmonic product
                return freqGrid.map { omega in
                        var logSum = 0.0
                        var validHarmonics = 0
                        
                        // Evaluate MUSIC pseudospectrum at each harmonic
                        for h in 0..<numHarmonics {
                                let harmonicFreq = omega * Double(h + 1)  // ω, 2ω, 3ω, 4ω, 5ω
                                
                                // Skip if harmonic is above Nyquist
                                if harmonicFreq >= Double.pi {
                                        continue
                                }
                                
                                let weight = harmonicWeights[h]
                                let P_harmonic = singleFrequencyPseudospectrum(omega: harmonicFreq)
                                
                                // Add weighted log-pseudospectrum
                                logSum += weight * log(P_harmonic)
                                validHarmonics += 1
                        }
                        
                        // Return geometric mean (normalized by number of valid harmonics)
                        if validHarmonics > 0 {
                                return exp(logSum / Double(validHarmonics))
                        } else {
                                return 0.0
                        }
                }
        }
        
        /// Peak-finding: returns top `sourceCount` frequencies in Hz
        mutating func estimatePeaks() -> [Double] {
                let spec = pseudospectrum()
                let freqsHz = freqGrid.map { Double($0) * store.audioSampleRate / (2*Double.pi) }
                return Array(zip(freqsHz, spec)
                        .sorted(by: { $0.1 > $1.1 })
                        .prefix(sourceCount)
                        .map { $0.0 })
        }
}
