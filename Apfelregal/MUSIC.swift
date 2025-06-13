import Foundation
import Accelerate
import SwiftUI

/// Core HMUSIC implementation for 1D frequency estimation
struct MUSIC {
        let store: TuningParameterStore
        let sourceCount: Int
        var freqGrid: [Double] = []     // Make it mutable and initially empty
        var snapshotMatrix: [DSPComplex] // flattened: M rows × N cols
        let subarrayLength: Int     // M
        let snapshotCount: Int      // N
        
        // HMUSIC parameters
        let numHarmonics: Int = 5   // L in the math notation
        
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
        
        /// Create harmonic steering matrix A(ω) = [a(ω), a(2ω), ..., a(Lω)]
        func createHarmonicSteeringMatrix(omega: Double) -> [DSPDoubleComplex] {
                let M = subarrayLength
                let L = numHarmonics
                
                // Matrix stored column-major: M rows × L columns
                var A = [DSPDoubleComplex](repeating: DSPDoubleComplex(), count: M * L)
                
                for harmonic in 0..<L {
                        let harmonicOmega = omega * Double(harmonic + 1)  // ω, 2ω, 3ω, ...
                        
                        // Skip if harmonic is above Nyquist
                        if harmonicOmega >= Double.pi {
                                // Fill with zeros for this harmonic
                                for m in 0..<M {
                                        let idx = harmonic * M + m  // Column-major indexing
                                        A[idx] = DSPDoubleComplex(real: 0.0, imag: 0.0)
                                }
                        } else {
                                // Fill the harmonic's steering vector
                                for m in 0..<M {
                                        let phase = -harmonicOmega * Double(m)
                                        let idx = harmonic * M + m  // Column-major indexing
                                        A[idx] = DSPDoubleComplex(real: cos(phase), imag: sin(phase))
                                }
                        }
                }
                
                return A
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
                // For HMUSIC, we need to account for the fact that each source contributes L harmonics
                let totalHarmonics = sourceCount * numHarmonics
                noiseDim = M - min(totalHarmonics, M - 1)  // Ensure we have at least 1 noise dimension
                
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
        
        /// Compute HMUSIC pseudospectrum value for a single frequency
        func hMusicPseudospectrum(omega: Double) -> Double {
                guard let noiseVecs = noiseSubspace else {
                        fatalError("Noise subspace not computed")
                }
                
                let M = subarrayLength
                let L = numHarmonics
                
                // Create harmonic steering matrix A(ω)
                let A = createHarmonicSteeringMatrix(omega: omega)
                
                // Compute U_n^H * A using BLAS zgemm
                // Result is noiseDim × L matrix
                var UnHA = [DSPDoubleComplex](repeating: DSPDoubleComplex(), count: noiseDim * L)
                var alpha = DSPDoubleComplex(real: 1.0, imag: 0.0)
                var beta = DSPDoubleComplex(real: 0.0, imag: 0.0)
                
                noiseVecs.withUnsafeBufferPointer { Unptr in
                        A.withUnsafeBufferPointer { Aptr in
                                UnHA.withUnsafeMutableBufferPointer { UnHAptr in
                                        withUnsafePointer(to: &alpha) { alphaPtr in
                                                withUnsafePointer(to: &beta) { betaPtr in
                                                        // UnHA = alpha * Un^H * A + beta * UnHA
                                                        cblas_zgemm(
                                                                CblasColMajor,      // matrix storage order
                                                                CblasConjTrans,     // conjugate transpose Un
                                                                CblasNoTrans,       // no transpose A
                                                                Int(noiseDim),      // rows of result
                                                                Int(L),             // columns of result
                                                                Int(M),             // common dimension
                                                                OpaquePointer(alphaPtr),           // scaling factor
                                                                OpaquePointer(Unptr.baseAddress),  // matrix Un
                                                                Int(M),             // leading dimension of Un
                                                                OpaquePointer(Aptr.baseAddress),   // matrix A
                                                                Int(M),             // leading dimension of A
                                                                OpaquePointer(betaPtr),            // scaling for result
                                                                OpaquePointer(UnHAptr.baseAddress),// output matrix
                                                                Int(noiseDim)       // leading dimension of result
                                                        )
                                                }
                                        }
                                }
                        }
                }
                
                // Compute trace[A^H * Un * Un^H * A] = ||Un^H * A||_F^2 (Frobenius norm squared)
                var trace = 0.0
                for i in 0..<(noiseDim * L) {
                        trace += UnHA[i].real * UnHA[i].real + UnHA[i].imag * UnHA[i].imag
                }
                
                // HMUSIC pseudospectrum formula: P_HMUSIC(ω) = L(M-L) / trace[A^H * Un * Un^H * A]
                let normalizationFactor = Double(L * (M - L))
                return normalizationFactor / max(trace, 1e-12)
        }
        
        /// Compute HMUSIC pseudospectrum over the frequency grid
        mutating func pseudospectrum() -> [Double] {
                // Update grid if needed before computing spectrum
                updateFrequencyGrid()
                
                // Ensure noise subspace is computed
                computeNoiseSubspace()
                
                // For each frequency in the grid, compute HMUSIC pseudospectrum
                return freqGrid.map { omega in
                        hMusicPseudospectrum(omega: omega)
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
