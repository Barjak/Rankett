import Foundation
import Accelerate

final class MUSICProcessor {
        let sourceCount: Int
        let gridResolution: Int
        
        private var maxSubarrayLength: Int
        private var maxSnapshotCount: Int
        
        private var snapshotBuffer: UnsafeMutablePointer<DSPDoubleComplex>
        private var covarianceBuffer: UnsafeMutablePointer<DSPDoubleComplex>
        private var eigenvalueBuffer: UnsafeMutablePointer<Double>
        private var noiseSubspaceBuffer: UnsafeMutablePointer<DSPDoubleComplex>
        private var steeringVectorBuffer: UnsafeMutablePointer<DSPDoubleComplex>
        private var tempVectorBuffer: UnsafeMutablePointer<DSPDoubleComplex>
        private let pseudospectrumBuffer: UnsafeMutablePointer<Double>
        private let frequencyGridBuffer: UnsafeMutablePointer<Double>
        
        private var eigenWorkspace: UnsafeMutablePointer<DSPDoubleComplex>
        private var eigenRworkBuffer: UnsafeMutablePointer<Double>
        private var eigenWorkspaceSize: Int
        
        init(sourceCount: Int, gridResolution: Int = 1024) {
                precondition(sourceCount > 0)
                precondition(gridResolution > 0)
                
                self.sourceCount = sourceCount
                self.gridResolution = gridResolution
                
                self.maxSubarrayLength = 128
                self.maxSnapshotCount = 256
                
                self.snapshotBuffer = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: maxSubarrayLength * maxSnapshotCount)
                self.covarianceBuffer = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: maxSubarrayLength * maxSubarrayLength)
                self.eigenvalueBuffer = UnsafeMutablePointer<Double>.allocate(capacity: maxSubarrayLength)
                self.noiseSubspaceBuffer = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: maxSubarrayLength * maxSubarrayLength)
                self.steeringVectorBuffer = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: maxSubarrayLength)
                self.tempVectorBuffer = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: maxSubarrayLength)
                self.pseudospectrumBuffer = UnsafeMutablePointer<Double>.allocate(capacity: gridResolution)
                self.frequencyGridBuffer = UnsafeMutablePointer<Double>.allocate(capacity: gridResolution)
                self.eigenRworkBuffer = UnsafeMutablePointer<Double>.allocate(capacity: max(1, 3 * maxSubarrayLength - 2))
                
                self.pseudospectrumBuffer.initialize(repeating: 0, count: gridResolution)
                self.frequencyGridBuffer.initialize(repeating: 0, count: gridResolution)
                
                var jobz: Int8 = Int8(UnicodeScalar("V").value)
                var uplo: Int8 = Int8(UnicodeScalar("U").value)
                var n = Int(maxSubarrayLength)
                var lda = Int(maxSubarrayLength)
                var info = Int(0)
                var lwork = Int(-1)
                var workQuery = DSPDoubleComplex()
                

                self.eigenWorkspaceSize = Int(workQuery.real)
                self.eigenWorkspace = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: eigenWorkspaceSize)
                withUnsafeMutablePointer(to: &workQuery) { workPtr in
                        zheev_(&jobz, &uplo, &n,
                               OpaquePointer(covarianceBuffer), &lda,
                               eigenvalueBuffer,
                               OpaquePointer(workPtr), &lwork,
                               eigenRworkBuffer,
                               &info)
                }
        }
        
        deinit {
                snapshotBuffer.deallocate()
                covarianceBuffer.deallocate()
                eigenvalueBuffer.deallocate()
                noiseSubspaceBuffer.deallocate()
                steeringVectorBuffer.deallocate()
                tempVectorBuffer.deallocate()
                pseudospectrumBuffer.deallocate()
                frequencyGridBuffer.deallocate()
                eigenRworkBuffer.deallocate()
                eigenWorkspace.deallocate()
        }
        
        func processComplexSamples(_ samples: ArraySlice<DSPDoubleComplex>,
                                   sampleRate: Double,
                                   minFreq: Double,
                                   maxFreq: Double,
                                   subarrayLength: Int,
                                   snapshotCount: Int) -> (spectrum: ArraySlice<Double>, frequencies: ArraySlice<Double>) {
                
                precondition(subarrayLength > sourceCount)
                precondition(snapshotCount > 0)
                
                guard samples.count >= subarrayLength else {
                        return (ArraySlice(UnsafeBufferPointer(start: pseudospectrumBuffer, count: 0)),
                                ArraySlice(UnsafeBufferPointer(start: frequencyGridBuffer, count: 0)))
                }
                
                ensureCapacity(subarrayLength: subarrayLength, snapshotCount: snapshotCount)
                
                let actualSnapshots = min(samples.count - subarrayLength + 1, snapshotCount)
                
                fillSnapshotsFromComplex(samples, subarrayLength: subarrayLength, snapshotCount: actualSnapshots)
                updateFrequencyGrid(minFreq: minFreq, maxFreq: maxFreq, sampleRate: sampleRate)
                computePseudospectrum(sampleRate: sampleRate, subarrayLength: subarrayLength, snapshotCount: actualSnapshots)
                
                return (ArraySlice(UnsafeBufferPointer(start: pseudospectrumBuffer, count: gridResolution)),
                        ArraySlice(UnsafeBufferPointer(start: frequencyGridBuffer, count: gridResolution)))
        }
        
        func findPeaks(count: Int? = nil) -> ArraySlice<Double> {
                let peakCount = min(count ?? sourceCount, sourceCount)
                
                var indices = Array(0..<gridResolution)
                indices.sort { pseudospectrumBuffer[$0] > pseudospectrumBuffer[$1] }
                
                var peaks = [Double](repeating: 0, count: peakCount)
                for i in 0..<peakCount {
                        peaks[i] = frequencyGridBuffer[indices[i]]
                }
                
                return ArraySlice(peaks)
        }
        
        private func ensureCapacity(subarrayLength: Int, snapshotCount: Int) {
                let needsResize = subarrayLength > maxSubarrayLength || snapshotCount > maxSnapshotCount
                
                guard needsResize else { return }
                
                let newSubarrayLength = max(subarrayLength, maxSubarrayLength)
                let newSnapshotCount = max(snapshotCount, maxSnapshotCount)
                
                snapshotBuffer.deallocate()
                covarianceBuffer.deallocate()
                eigenvalueBuffer.deallocate()
                noiseSubspaceBuffer.deallocate()
                steeringVectorBuffer.deallocate()
                tempVectorBuffer.deallocate()
                eigenRworkBuffer.deallocate()
                eigenWorkspace.deallocate()
                
                snapshotBuffer = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: newSubarrayLength * newSnapshotCount)
                covarianceBuffer = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: newSubarrayLength * newSubarrayLength)
                eigenvalueBuffer = UnsafeMutablePointer<Double>.allocate(capacity: newSubarrayLength)
                noiseSubspaceBuffer = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: newSubarrayLength * newSubarrayLength)
                steeringVectorBuffer = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: newSubarrayLength)
                tempVectorBuffer = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: newSubarrayLength)
                eigenRworkBuffer = UnsafeMutablePointer<Double>.allocate(capacity: max(1, 3 * newSubarrayLength - 2))
                
                var jobz: Int8 = Int8(UnicodeScalar("V").value)
                var uplo: Int8 = Int8(UnicodeScalar("U").value)
                var n = Int(newSubarrayLength)
                var lda = Int(newSubarrayLength)
                var info = Int(0)
                var lwork = Int(-1)
                var workQuery = DSPDoubleComplex()
                

                eigenWorkspaceSize = Int(workQuery.real)
                eigenWorkspace = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: eigenWorkspaceSize)
                zheev_(&jobz, &uplo, &n,
                       OpaquePointer(noiseSubspaceBuffer), &lda,
                       eigenvalueBuffer,
                       OpaquePointer(eigenWorkspace), &lwork,
                       eigenRworkBuffer,
                       &info)
                
                maxSubarrayLength = newSubarrayLength
                maxSnapshotCount = newSnapshotCount
        }
        
        private func fillSnapshotsFromComplex(_ samples: ArraySlice<DSPDoubleComplex>,
                                              subarrayLength: Int,
                                              snapshotCount: Int) {
                let stride = max(1, (samples.count - subarrayLength + 1) / snapshotCount)
                
                samples.withUnsafeBufferPointer { samplesPtr in
                        let basePtr = samplesPtr.baseAddress!
                        
                        for n in 0..<snapshotCount {
                                let startIdx = min(n * stride, samples.count - subarrayLength)
                                memcpy(snapshotBuffer + n * subarrayLength,
                                       basePtr + startIdx,
                                       subarrayLength * MemoryLayout<DSPDoubleComplex>.size)
                        }
                }
        }
        
        private func updateFrequencyGrid(minFreq: Double, maxFreq: Double, sampleRate: Double) {
                let omegaLow = 2.0 * .pi * minFreq / sampleRate
                let omegaHigh = 2.0 * .pi * maxFreq / sampleRate
                
                let logLow = log(omegaLow)
                let logHigh = log(omegaHigh)
                
                for i in 0..<gridResolution {
                        let t = Double(i) / Double(gridResolution - 1)
                        let logOmega = logLow + t * (logHigh - logLow)
                        let omega = exp(logOmega)
                        frequencyGridBuffer[i] = omega * sampleRate / (2.0 * .pi)
                }
        }
        
        private func computePseudospectrum(sampleRate: Double, subarrayLength: Int, snapshotCount: Int) {
                computeCovariance(subarrayLength: subarrayLength, snapshotCount: snapshotCount)
                computeEigendecomposition(subarrayLength: subarrayLength)
                
                let noiseDim = subarrayLength - sourceCount
                extractNoiseSubspace(subarrayLength: subarrayLength, noiseDim: noiseDim)
                
                for i in 0..<gridResolution {
                        let omega = 2.0 * .pi * frequencyGridBuffer[i] / sampleRate
                        computeSteeringVector(omega: omega, subarrayLength: subarrayLength)
                        pseudospectrumBuffer[i] = computeMUSICValue(subarrayLength: subarrayLength, noiseDim: noiseDim)
                }
                
                normalizeSpectrum()
        }
        
        private func computeCovariance(subarrayLength: Int, snapshotCount: Int) {
                var alpha = DSPDoubleComplex(real: 1.0 / Double(snapshotCount), imag: 0.0)
                var beta = DSPDoubleComplex(real: 0.0, imag: 0.0)
                
                withUnsafePointer(to: &alpha) { alphaPtr in
                        withUnsafePointer(to: &beta) { betaPtr in
                                cblas_zgemm(CblasColMajor, CblasNoTrans, CblasConjTrans,
                                            Int(subarrayLength), Int(subarrayLength), Int(snapshotCount),
                                            OpaquePointer(alphaPtr),
                                            OpaquePointer(snapshotBuffer), Int(subarrayLength),
                                            OpaquePointer(snapshotBuffer), Int(subarrayLength),
                                            OpaquePointer(betaPtr),
                                            OpaquePointer(covarianceBuffer), Int(subarrayLength))
                        }
                }
        }
        
        private func computeEigendecomposition(subarrayLength: Int, regularization: Double = 1e-10) -> Bool {
                var jobz: Int8 = Int8(UnicodeScalar("V").value)
                var uplo: Int8 = Int8(UnicodeScalar("U").value)
                var n = Int(subarrayLength)
                var lda = Int(subarrayLength)
                var info = Int(0)
                var lwork = Int(eigenWorkspaceSize)
                
                memcpy(noiseSubspaceBuffer, covarianceBuffer,
                       subarrayLength * subarrayLength * MemoryLayout<DSPDoubleComplex>.size)
                
                zheev_(&jobz, &uplo, &n,
                       OpaquePointer(noiseSubspaceBuffer), &lda,
                       eigenvalueBuffer,
                       OpaquePointer(eigenWorkspace), &lwork,
                       eigenRworkBuffer,
                       &info)
                
                if info != 0 {
                        // Add regularization to diagonal and retry
                        let stride = subarrayLength + 1
                        for i in 0..<subarrayLength {
                                noiseSubspaceBuffer[i * stride].real += regularization
                        }
                        
                        info = 0
                        zheev_(&jobz, &uplo, &n,
                               OpaquePointer(noiseSubspaceBuffer), &lda,
                               eigenvalueBuffer,
                               OpaquePointer(eigenWorkspace), &lwork,
                               eigenRworkBuffer,
                               &info)
                }
                
                return info == 0
        }
        
        private func extractNoiseSubspace(subarrayLength: Int, noiseDim: Int) {
                let tempBuffer = UnsafeMutablePointer<DSPDoubleComplex>.allocate(capacity: subarrayLength * noiseDim)
                defer { tempBuffer.deallocate() }
                
                for k in 0..<noiseDim {
                        for i in 0..<subarrayLength {
                                let srcIdx = k * subarrayLength + i
                                tempBuffer[i * noiseDim + k] = noiseSubspaceBuffer[srcIdx]
                        }
                }
                
                memcpy(noiseSubspaceBuffer, tempBuffer, subarrayLength * noiseDim * MemoryLayout<DSPDoubleComplex>.size)
        }
        
        private func computeSteeringVector(omega: Double, subarrayLength: Int) {
                for m in 0..<subarrayLength {
                        let phase = -omega * Double(m)
                        steeringVectorBuffer[m] = DSPDoubleComplex(real: cos(phase), imag: sin(phase))
                }
        }
        
        private func computeMUSICValue(subarrayLength: Int, noiseDim: Int) -> Double {
                var alpha = DSPDoubleComplex(real: 1.0, imag: 0.0)
                var beta = DSPDoubleComplex(real: 0.0, imag: 0.0)
                
                withUnsafePointer(to: &alpha) { alphaPtr in
                        withUnsafePointer(to: &beta) { betaPtr in
                                cblas_zgemv(CblasColMajor, CblasConjTrans,
                                            Int(subarrayLength), Int(noiseDim),
                                            OpaquePointer(alphaPtr),
                                            OpaquePointer(noiseSubspaceBuffer), Int(subarrayLength),
                                            OpaquePointer(steeringVectorBuffer), 1,
                                            OpaquePointer(betaPtr),
                                            OpaquePointer(tempVectorBuffer), 1)
                        }
                }
                
                var realPart = 0.0
                var imagPart = 0.0
                
                for i in 0..<noiseDim {
                        realPart += tempVectorBuffer[i].real * tempVectorBuffer[i].real
                        imagPart += tempVectorBuffer[i].imag * tempVectorBuffer[i].imag
                }
                
                let power = realPart + imagPart
                return 1.0 / max(power, 1e-12)
        }
        
        private func normalizeSpectrum() {
                var maxValue: Double = 0.0
                vDSP_maxvD(pseudospectrumBuffer, 1, &maxValue, vDSP_Length(gridResolution))
                
                if maxValue > 0 {
                        var scale = 1.0 / maxValue
                        vDSP_vsmulD(pseudospectrumBuffer, 1, &scale, pseudospectrumBuffer, 1, vDSP_Length(gridResolution))
                }
        }
}
