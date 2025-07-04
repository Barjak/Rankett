import numpy as np
import matplotlib.pyplot as plt
from scipy import signal
import matplotlib.gridspec as gridspec
from matplotlib.patches import Circle
import matplotlib.cm as cm

class DualEKFAnalyzer:
    def __init__(self, fs_baseband=960.0):
        self.fs = fs_baseband
        self.dt = 1.0 / fs_baseband
        
    def dual_ekf_tracking(self, signal_data, f1_init, f2_init, 
                      Q=None, R=None, P0=None,
                      track_amplitude=True,
                      min_separation_hz=0.003,  # 3 mHz minimum
                      separation_weight=0.01):
        """
        Dual-tone tracking using Extended Kalman Filter
        
        State vector: x = [phi1, w1, phi2, w2, A1, A2]
        where phi_i = phase, w_i = angular frequency, A_i = amplitude
        """
        n_samples = len(signal_data)
        dt = self.dt
        min_separation_rad = 2 * np.pi * min_separation_hz
        
        # State transition matrix
        F = np.array([[1, dt, 0,  0, 0, 0],
                      [0,  1, 0,  0, 0, 0],
                      [0,  0, 1, dt, 0, 0],
                      [0,  0, 0,  1, 0, 0],
                      [0,  0, 0,  0, 1, 0],
                      [0,  0, 0,  0, 0, 1]])
        
        # Initialize state
        x = np.array([0.0,                    # phi1
                      2*np.pi*f1_init,        # w1
                      0.0,                    # phi2
                      2*np.pi*f2_init,        # w2
                      1.0,                    # A1
                      0.7])                   # A2
        
        # Process noise covariance
        if Q is None:
            # Tune these based on expected signal characteristics
            sigma_phi = 1e-6      # Phase noise (very small)
            sigma_w = 1e-3        # Frequency drift
            sigma_A = 1e-4        # Amplitude drift
            Q = np.diag([sigma_phi**2, sigma_w**2, 
                         sigma_phi**2, sigma_w**2,
                         sigma_A**2, sigma_A**2])
        
        # Measurement noise covariance
        if R is None:
            R = 0.01**1.1  # Based on noise level in signal
        
        # Initial state covariance
        if P0 is None:
            P0 = np.diag([0.1,    # phi1 uncertainty
                          0.1,    # w1 uncertainty (rad/s)
                          0.1,    # phi2 uncertainty
                          0.1,    # w2 uncertainty (rad/s)
                          0.01,   # A1 uncertainty
                          0.01])  # A2 uncertainty
        
        P = P0.copy()
        
        # Storage for analysis
        history = {
            'x': [x.copy()],
            'P': [P.copy()],
            'y_pred': [],
            'innov': [],
            'freq1': [f1_init],
            'freq2': [f2_init],
            'A1': [x[4]],
            'A2': [x[5]],
            'phase1': [x[0]],
            'phase2': [x[2]],
            'separation': [abs(f2_init - f1_init)],
            'error': [],
            'K': []  # Kalman gain
        }
        
        # Main EKF loop
        for k, y in enumerate(signal_data):
            # ---- Predict ----
            x = F @ x
            P = F @ P @ F.T + Q
            
            # Wrap phases to [-pi, pi]
            x[0] = np.angle(np.exp(1j * x[0]))
            x[2] = np.angle(np.exp(1j * x[2]))
            
            # ---- Measurement prediction ----
            phi1, w1, phi2, w2, A1, A2 = x
            
            # Complex measurement prediction
            y_hat = A1 * np.exp(1j * phi1) + A2 * np.exp(1j * phi2)
            
            # ---- Compute Jacobian H ----
            # We'll treat the complex measurement as [Re(y), Im(y)]
            H = np.zeros((2, 6))
            
            # Derivatives w.r.t phi1
            H[0, 0] = -A1 * np.sin(phi1)  # dRe/dphi1
            H[1, 0] = A1 * np.cos(phi1)   # dIm/dphi1
            
            # Derivatives w.r.t w1 (zero for instantaneous measurement)
            H[0, 1] = 0
            H[1, 1] = 0
            
            # Derivatives w.r.t phi2
            H[0, 2] = -A2 * np.sin(phi2)  # dRe/dphi2
            H[1, 2] = A2 * np.cos(phi2)   # dIm/dphi2
            
            # Derivatives w.r.t w2 (zero for instantaneous measurement)
            H[0, 3] = 0
            H[1, 3] = 0
            
            if track_amplitude:
                # Derivatives w.r.t A1
                H[0, 4] = np.cos(phi1)  # dRe/dA1
                H[1, 4] = np.sin(phi1)  # dIm/dA1
                
                # Derivatives w.r.t A2
                H[0, 5] = np.cos(phi2)  # dRe/dA2
                H[1, 5] = np.sin(phi2)  # dIm/dA2
            else:
                # Don't update amplitudes
                H[0, 4] = 0
                H[1, 4] = 0
                H[0, 5] = 0
                H[1, 5] = 0
            
            # ---- Innovation ----
            z = np.array([np.real(y), np.imag(y)])
            z_hat = np.array([np.real(y_hat), np.imag(y_hat)])
            innov = z - z_hat
            
            # ---- Kalman gain ----
            S = H @ P @ H.T + R * np.eye(2)
            K = P @ H.T @ np.linalg.inv(S)
            
            # ---- Update ----
            x_before = x.copy()
        
            x = x + K @ innov
            
            w1_new, w2_new = x[1], x[3]
            separation = abs(w2_new - w1_new)
                    
            if separation < min_separation_rad:
                # Compute regularization force
                # This pushes frequencies apart when they get too close
                sign = np.sign(w2_new - w1_new)
                if sign == 0:  # If exactly equal, use initial ordering
                    sign = np.sign(f2_init - f1_init)
                
                # Soft constraint: gradually increase force as separation decreases
                force = separation_weight * (min_separation_rad - separation) / min_separation_rad
                
                # Apply symmetric push to maintain center frequency
                x[1] -= force * min_separation_rad * sign / 2
                x[3] += force * min_separation_rad * sign / 2
                
                # Optional: Adjust covariance to reflect this constraint
                # Increase uncertainty in frequency estimates when regularization is active
                P[1, 1] *= (1 + force)
                P[3, 3] *= (1 + force)
      
            
            P = (np.eye(len(x)) - K @ H) @ P
            
            # Ensure positive amplitudes
            if track_amplitude:
                x[4] = max(0.1, x[4])
                x[5] = max(0.1, x[5])
            
            # ---- Store results ----
            history['x'].append(x.copy())
            history['P'].append(P.copy())
            history['y_pred'].append(y_hat)
            history['innov'].append(innov)
            history['freq1'].append(x[1] / (2 * np.pi))  # Convert to Hz
            history['freq2'].append(x[3] / (2 * np.pi))  # Convert to Hz
            history['A1'].append(x[4])
            history['A2'].append(x[5])
            history['phase1'].append(x[0])
            history['phase2'].append(x[2])
            history['separation'].append(abs(x[3] - x[1]) / (2 * np.pi))
            history['error'].append(np.abs(y - y_hat))
            history['K'].append(K.copy())
        
        # Convert lists to arrays
        for key in history:
            if key not in ['x', 'P', 'K']:
                history[key] = np.array(history[key])
        
        # Compute final estimates (average over last quarter of samples)
        converged_f1 = np.mean(history['freq1'][-n_samples//4:])
        converged_f2 = np.mean(history['freq2'][-n_samples//4:])
        converged_A1 = np.mean(history['A1'][-n_samples//4:])
        converged_A2 = np.mean(history['A2'][-n_samples//4:])
        
        return {
            'f1': converged_f1,
            'f2': converged_f2,
            'beat': converged_f2 - converged_f1,
            'A1': converged_A1,
            'A2': converged_A2,
            'history': history
        }
    
    def hybrid_ekf_pll_tracking(self, signal_data, f1_init, f2_init,
                               ekf_duration_fraction=0.2,
                               convergence_threshold_mhz=1.0,
                               min_separation_hz=0.003,
                               track_amplitude=True):
        """
        Hybrid EKF-PLL tracking: EKF for acquisition, PLL for tracking
        
        Parameters:
        - ekf_duration_fraction: Fraction of signal to use for EKF (default 0.2 = 20%)
        - convergence_threshold_mhz: Uncertainty threshold for handoff (mHz)
        - min_separation_hz: Minimum frequency separation (Hz)
        - track_amplitude: Whether to track amplitudes
        """
        n_samples = len(signal_data)
        ekf_samples = int(n_samples * ekf_duration_fraction)
        pll_samples = n_samples - ekf_samples
        
        # Phase 1: EKF Acquisition
        # Use higher process noise for faster acquisition
        sigma_phi = 1e-6
        sigma_w = 5e-3  # Higher for faster adaptation
        sigma_A = 1e-3
        Q_ekf = np.diag([sigma_phi**2, sigma_w**2, 
                         sigma_phi**2, sigma_w**2,
                         sigma_A**2, sigma_A**2])
        
        ekf_result = self.dual_ekf_tracking(
            signal_data[:ekf_samples], 
            f1_init, f2_init,
            Q=Q_ekf, R=0.01**2,
            track_amplitude=track_amplitude,
            min_separation_hz=min_separation_hz
        )
        
        # Extract final EKF state
        final_state = ekf_result['history']['x'][-1]
        final_P = ekf_result['history']['P'][-1]
        
        # Check convergence criteria
        std_f1_mhz = np.sqrt(final_P[1,1]) / (2*np.pi) * 1000
        std_f2_mhz = np.sqrt(final_P[3,3]) / (2*np.pi) * 1000
        innov_magnitude = np.mean(np.sqrt(np.array(ekf_result['history']['innov'])[-50:, 0]**2 + 
                                         np.array(ekf_result['history']['innov'])[-50:, 1]**2))
        
        converged = (std_f1_mhz < convergence_threshold_mhz and 
                    std_f2_mhz < convergence_threshold_mhz and
                    innov_magnitude < 0.05)
        
        # Phase 2: PLL Tracking
        if converged and pll_samples > 0:
            # Extract handoff parameters
            phi1_handoff = final_state[0]
            f1_handoff = final_state[1] / (2 * np.pi)
            phi2_handoff = final_state[2]
            f2_handoff = final_state[3] / (2 * np.pi)
            A1_handoff = final_state[4]
            A2_handoff = final_state[5]
            
            # Run PLL from handoff point
            pll_result = self._dual_pll_tracking(
                signal_data[ekf_samples:],
                f1_handoff, f2_handoff,
                phi1_init=phi1_handoff,
                phi2_init=phi2_handoff,
                A1_init=A1_handoff,
                A2_init=A2_handoff,
                track_amplitude=track_amplitude,
                min_separation_hz=min_separation_hz,
                loop_bw=0.2  # Tighter bandwidth since we're already close
            )
            
            # Combine histories
            combined_history = {}
            for key in ekf_result['history']:
                if key in ['x', 'P', 'K']:
                    combined_history[key] = ekf_result['history'][key]
                else:
                    combined_history[key] = np.concatenate([
                        ekf_result['history'][key],
                        pll_result['history'][key]
                    ])
            
            # Mark handoff point
            combined_history['handoff_sample'] = ekf_samples
            combined_history['handoff_converged'] = True
            combined_history['std_f1_at_handoff'] = std_f1_mhz
            combined_history['std_f2_at_handoff'] = std_f2_mhz
            
            # Final estimates from PLL
            return {
                'f1': pll_result['f1'],
                'f2': pll_result['f2'],
                'beat': pll_result['beat'],
                'A1': pll_result['A1'],
                'A2': pll_result['A2'],
                'history': combined_history,
                'method': 'hybrid_ekf_pll'
            }
        else:
            # Didn't converge or no PLL samples - use EKF only
            ekf_full = self.dual_ekf_tracking(
                signal_data, f1_init, f2_init,
                Q=Q_ekf, R=0.01**2,
                track_amplitude=track_amplitude,
                min_separation_hz=min_separation_hz
            )
            ekf_full['history']['handoff_sample'] = -1
            ekf_full['history']['handoff_converged'] = False
            ekf_full['method'] = 'ekf_only'
            return ekf_full
    
    def _dual_pll_tracking(self, signal_data, f1_init, f2_init,
                          phi1_init=0.0, phi2_init=0.0,
                          A1_init=1.0, A2_init=0.7,
                          track_amplitude=False,
                          min_separation_hz=0.003,
                          loop_bw=0.5):
        """
        Dual PLL tracking (based on DualPLLAnalyzer implementation)
        """
        n_samples = len(signal_data)
        
        # Initialize from handoff
        phase1, phase2 = phi1_init, phi2_init
        freq1, freq2 = f1_init, f2_init
        A1, A2 = A1_init, A2_init
        
        # PLL parameters
        damping = 1.0
        theta = 2 * np.pi * loop_bw / self.fs
        d = 1 + 2 * damping * theta + theta**2
        g1 = 4 * damping * theta / d
        g2 = 4 * theta**2 / d
        
        # Storage
        history = {
            'freq1': [freq1],
            'freq2': [freq2],
            'A1': [A1],
            'A2': [A2],
            'phase1': [phase1],
            'phase2': [phase2],
            'separation': [abs(freq2 - freq1)],
            'error': [],
            'phase_error1': [],
            'phase_error2': []
        }
        
        # Loop filter integrals
        phase_error1_integral = 0
        phase_error2_integral = 0
        
        # Regularization
        freq_regularization = 0.1
        amplitude_regularization = 0.1
        
        for i, sample in enumerate(signal_data):
            # Generate NCOs
            nco1 = np.exp(1j * phase1)
            nco2 = np.exp(1j * phase2)
            
            # Current signal estimate
            if track_amplitude:
                signal_est = A1 * nco1 + A2 * nco2
            else:
                # Simple correlation for fixed amplitudes
                a1 = sample * np.conj(nco1)
                a2 = sample * np.conj(nco2)
                signal_est = A1 * nco1 + A2 * nco2
            
            # Error
            error = sample - signal_est
            history['error'].append(np.abs(error))
            
            # Phase errors
            if track_amplitude:
                phase_error1 = np.real(np.conj(error) * 1j * A1 * nco1)
                phase_error2 = np.real(np.conj(error) * 1j * A2 * nco2)
            else:
                phase_error1 = np.real(np.conj(error) * 1j * A1 * nco1)
                phase_error2 = np.real(np.conj(error) * 1j * A2 * nco2)
            
            history['phase_error1'].append(phase_error1)
            history['phase_error2'].append(phase_error2)
            
            # Regularization force
            separation = abs(freq2 - freq1)
            if separation < min_separation_hz:
                reg_force = freq_regularization * (min_separation_hz - separation) / min_separation_hz
                if freq2 > freq1:
                    phase_error2 += reg_force
                    phase_error1 -= reg_force
                else:
                    phase_error2 -= reg_force
                    phase_error1 += reg_force
            
            # Update frequencies
            phase_error1_integral += phase_error1
            phase_error2_integral += phase_error2
            
            freq1 = f1_init + g1 * phase_error1 + g2 * phase_error1_integral
            freq2 = f2_init + g1 * phase_error2 + g2 * phase_error2_integral
            
            # Update phases
            phase1 += 2 * np.pi * freq1 / self.fs
            phase2 += 2 * np.pi * freq2 / self.fs
            phase1 = np.angle(np.exp(1j * phase1))
            phase2 = np.angle(np.exp(1j * phase2))
            
            # Update amplitudes if tracking
            if track_amplitude:
                # Gradient descent on amplitudes with regularization
                learning_rate = 0.01
                
                dA1 = -2 * np.real(np.conj(error) * nco1)
                dA2 = -2 * np.real(np.conj(error) * nco2)
                
                # Add regularization gradient
                dA1 += amplitude_regularization * (A1 - 1.0)
                dA2 += amplitude_regularization * (A2 - 0.7)
                
                A1 -= learning_rate * dA1
                A2 -= learning_rate * dA2
                
                # Constrain to positive
                A1 = max(0.1, A1)
                A2 = max(0.1, A2)
            
            # Store history
            history['freq1'].append(freq1)
            history['freq2'].append(freq2)
            history['A1'].append(A1)
            history['A2'].append(A2)
            history['phase1'].append(phase1)
            history['phase2'].append(phase2)
            history['separation'].append(abs(freq2 - freq1))
        
        # Convert to arrays
        for key in history:
            history[key] = np.array(history[key])
        
        # Final estimates
        converged_f1 = np.mean(history['freq1'][-n_samples//4:])
        converged_f2 = np.mean(history['freq2'][-n_samples//4:])
        converged_A1 = np.mean(history['A1'][-n_samples//4:])
        converged_A2 = np.mean(history['A2'][-n_samples//4:])
        
        return {
            'f1': converged_f1,
            'f2': converged_f2,
            'beat': converged_f2 - converged_f1,
            'A1': converged_A1,
            'A2': converged_A2,
            'history': history
        }
    
    def run_from_multiple_initializations(self, signal_data, f1_true, f2_true, Q=None, R=None):
        """Test EKF from various starting points"""
        
        # Define test cases
        test_cases = [
            # (f1_init, f2_init, label)
            (f1_true, f2_true, "Truth"),
            (f1_true - 0.010, f2_true + 0.010, "Far from truth"),
            (f2_true, f1_true, "Swapped"),
            (f1_true, f1_true + 0.001, "Very close"),
            (f1_true, f1_true + 0.020, "Far apart"),
            (f1_true - 0.005, f2_true + 0.005, "Symmetric offset"),
            (f1_true + 0.002, f2_true - 0.002, "Inward offset"),
            (5.5, 5.7, "Random far"),
        ]
        
        results = []
        for f1_init, f2_init, label in test_cases:
            result = self.dual_ekf_tracking(signal_data, f1_init, f2_init, Q=Q, R=R)
            result['label'] = label
            result['f1_init'] = f1_init
            result['f2_init'] = f2_init
            results.append(result)
        
        return results
    
    def run_hybrid_comparison(self, signal_data, f1_true, f2_true):
        """Compare EKF-only, PLL-only, and hybrid approaches"""
        
        # Test cases
        test_cases = [
            (f1_true - 0.010, f2_true + 0.010, "Far from truth"),
            (f2_true, f1_true, "Swapped"),
            (5.5, 5.7, "Random far"),
        ]
        
        results = []
        
        for f1_init, f2_init, label in test_cases:
            # EKF only
            ekf_result = self.dual_ekf_tracking(signal_data, f1_init, f2_init)
            ekf_result['label'] = f"EKF - {label}"
            ekf_result['method'] = 'ekf'
            ekf_result['f1_init'] = f1_init
            ekf_result['f2_init'] = f2_init
            results.append(ekf_result)
            
            # PLL only
            pll_result = self._dual_pll_tracking(signal_data, f1_init, f2_init,
                                               track_amplitude=True)
            pll_result['label'] = f"PLL - {label}"
            pll_result['method'] = 'pll'
            pll_result['f1_init'] = f1_init
            pll_result['f2_init'] = f2_init
            results.append(pll_result)
            
            # Hybrid
            hybrid_result = self.hybrid_ekf_pll_tracking(signal_data, f1_init, f2_init)
            hybrid_result['label'] = f"Hybrid - {label}"
            hybrid_result['f1_init'] = f1_init
            hybrid_result['f2_init'] = f2_init
            results.append(hybrid_result)
        
        return results
    
    def compute_error_landscape(self, signal_data, f1_range, f2_range, true_f1, true_f2):
        """Compute the error landscape for visualization"""
        n_points = 50
        f1_grid = np.linspace(f1_range[0], f1_range[1], n_points)
        f2_grid = np.linspace(f2_range[0], f2_range[1], n_points)
        
        error_landscape = np.zeros((n_points, n_points))
        
        # Pre-compute true signal for efficiency
        t = np.arange(len(signal_data)) / self.fs
        
        for i, f1 in enumerate(f1_grid):
            for j, f2 in enumerate(f2_grid):
                # Compute error for this (f1, f2) pair
                s1 = np.exp(1j * 2 * np.pi * f1 * t)
                s2 = 0.7 * np.exp(1j * 2 * np.pi * f2 * t)
                estimate = s1 + s2
                
                error = np.mean(np.abs(signal_data - estimate)**2)
                error_landscape[j, i] = error  # Note: j, i for proper orientation
        
        return f1_grid, f2_grid, error_landscape
    
    def visualize_ekf_analysis(self, results, signal_data, f1_true, f2_true):
        """Comprehensive visualization of EKF behavior"""
        
        fig = plt.figure(figsize=(20, 16))
        gs = gridspec.GridSpec(4, 4, figure=fig, hspace=0.3, wspace=0.3)
        
        # 1. 2D Phase Space Trajectories
        ax1 = fig.add_subplot(gs[0:2, 0:2])
        
        # Compute and plot error landscape
        f1_range = (f1_true - 0.015, f1_true + 0.015)
        f2_range = (f2_true - 0.015, f2_true + 0.015)
        f1_grid, f2_grid, error_landscape = self.compute_error_landscape(
            signal_data, f1_range, f2_range, f1_true, f2_true
        )
        
        # Plot error landscape as contours
        contour = ax1.contourf(f1_grid, f2_grid, np.log10(error_landscape + 1e-10), 
                               levels=20, cmap='viridis', alpha=0.6)
        
        # Plot trajectories
        colors = cm.rainbow(np.linspace(0, 1, len(results)))
        for result, color in zip(results, colors):
            history = result['history']
            
            # Check if this is a hybrid result with handoff
            if 'handoff_sample' in history and history['handoff_sample'] > 0:
                # Plot EKF portion
                ax1.plot(history['freq1'][:history['handoff_sample']], 
                        history['freq2'][:history['handoff_sample']], 
                        '-', color=color, linewidth=2, alpha=0.8)
                # Plot PLL portion with different style
                ax1.plot(history['freq1'][history['handoff_sample']:], 
                        history['freq2'][history['handoff_sample']:], 
                        '--', color=color, linewidth=2, alpha=0.8, 
                        label=result['label'])
                # Mark handoff point
                ax1.plot(history['freq1'][history['handoff_sample']], 
                        history['freq2'][history['handoff_sample']], 
                        'o', color=color, markersize=8, markeredgecolor='white')
            else:
                ax1.plot(history['freq1'], history['freq2'], '-', color=color, 
                        linewidth=2, alpha=0.8, label=result['label'])
            
            # Start point
            ax1.plot(result['f1_init'], result['f2_init'], 'o', 
                    color=color, markersize=10, markeredgecolor='black')
            # End point
            ax1.plot(history['freq1'][-1], history['freq2'][-1], 's', 
                    color=color, markersize=10, markeredgecolor='black')
        
        # True values
        ax1.plot(f1_true, f2_true, '*', color='red', markersize=20, 
                markeredgecolor='black', markeredgewidth=2, label='True')
        
        # Diagonal line (f1 = f2)
        diag_line = np.array([min(f1_range[0], f2_range[0]), 
                             max(f1_range[1], f2_range[1])])
        ax1.plot(diag_line, diag_line, 'k--', alpha=0.5, label='f1=f2')
        
        ax1.set_xlabel('f1 (Hz)')
        ax1.set_ylabel('f2 (Hz)')
        ax1.set_title('2D Frequency Space Trajectories (EKF)')
        ax1.legend(bbox_to_anchor=(1.05, 1), loc='upper left')
        ax1.grid(True, alpha=0.3)
        ax1.set_aspect('equal')
        
        # 2. Separation Evolution
        ax2 = fig.add_subplot(gs[0, 2:])
        
        for result, color in zip(results, colors):
            history = result['history']
            samples = np.arange(len(history['separation']))
            
            if 'handoff_sample' in history and history['handoff_sample'] > 0:
                ax2.axvline(history['handoff_sample'], color=color, 
                           linestyle=':', alpha=0.5)
            
            ax2.plot(samples, history['separation'] * 1000, '-', color=color, 
                    linewidth=2, label=result['label'])
        
        ax2.axhline(6.0, color='red', linestyle='--', linewidth=2, label='True separation')
        ax2.set_xlabel('Sample')
        ax2.set_ylabel('|f2 - f1| (mHz)')
        ax2.set_title('Frequency Separation Evolution')
        ax2.legend()
        ax2.grid(True, alpha=0.3)
        ax2.set_ylim([0, max(20, ax2.get_ylim()[1])])
        
        # 3. Uncertainty Evolution (from covariance) - only for EKF results
        ax3 = fig.add_subplot(gs[1, 2:])
        
        # Plot frequency uncertainty for EKF-based methods
        for result, color in zip(results, colors):
            if 'P' in result['history'] and result['history']['P']:
                P_history = result['history']['P']
                # Extract standard deviations for frequencies
                std_f1 = np.array([np.sqrt(P[1,1]) / (2*np.pi) * 1000 for P in P_history])  # mHz
                std_f2 = np.array([np.sqrt(P[3,3]) / (2*np.pi) * 1000 for P in P_history])  # mHz
                
                samples = np.arange(len(std_f1))
                ax3.plot(samples, std_f1, '-', color=color, linewidth=1, alpha=0.7)
                ax3.plot(samples, std_f2, '--', color=color, linewidth=1, alpha=0.7, 
                        label=result['label'])
                
                if 'handoff_sample' in result['history'] and result['history']['handoff_sample'] > 0:
                    ax3.axvline(result['history']['handoff_sample'], 
                               color=color, linestyle=':', alpha=0.5)
        
        ax3.set_xlabel('Sample')
        ax3.set_ylabel('Frequency Uncertainty (mHz)')
        ax3.set_title('EKF Uncertainty Evolution (solid=f1, dashed=f2)')
        ax3.legend()
        ax3.grid(True, alpha=0.3)
        ax3.set_yscale('log')
        
        # 4. Convergence Comparison
        ax4 = fig.add_subplot(gs[2, :2])
        
        # Bar chart of final errors
        labels = [r['label'] for r in results]
        f1_errors = [(r['f1'] - f1_true) * 1000 for r in results]
        f2_errors = [(r['f2'] - f2_true) * 1000 for r in results]
        beat_errors = [(r['beat'] - (f2_true - f1_true)) * 1000 for r in results]
        
        x = np.arange(len(labels))
        width = 0.25
        
        ax4.bar(x - width, f1_errors, width, label='f1 error', alpha=0.8)
        ax4.bar(x, f2_errors, width, label='f2 error', alpha=0.8)
        ax4.bar(x + width, beat_errors, width, label='beat error', alpha=0.8)
        
        ax4.set_xlabel('Initialization')
        ax4.set_ylabel('Error (mHz)')
        ax4.set_title('Final Estimation Errors')
        ax4.set_xticks(x)
        ax4.set_xticklabels(labels, rotation=45, ha='right')
        ax4.legend()
        ax4.grid(True, alpha=0.3, axis='y')
        ax4.axhline(0, color='black', linewidth=1)
        
        # 5. Signal Reconstruction
        ax5 = fig.add_subplot(gs[2, 2:])
        
        # Use the first result
        history = results[0]['history']
        
        # Reconstruct signals at a few time points
        t = np.arange(len(signal_data)) / self.fs
        time_points = [0, len(signal_data)//4, len(signal_data)//2, -1]
        
        for i, tp in enumerate(time_points):
            alpha = 0.3 + 0.7 * i / len(time_points)
            if tp == -1:
                label = 'Final'
            else:
                label = f'Sample {tp}'
                
            # Reconstruct
            s1 = history['A1'][tp] * np.exp(1j * 2 * np.pi * history['freq1'][tp] * t)
            s2 = history['A2'][tp] * np.exp(1j * 2 * np.pi * history['freq2'][tp] * t)
            reconstruction = s1 + s2
            
            if tp == -1:
                ax5.plot(t[:100], np.real(reconstruction[:100]), 'k-', 
                        linewidth=2, alpha=alpha, label=label)
            else:
                ax5.plot(t[:100], np.real(reconstruction[:100]), '-', 
                        linewidth=1, alpha=alpha, label=label)
        
        ax5.plot(t[:100], np.real(signal_data[:100]), 'r--', 
                linewidth=2, alpha=0.8, label='True signal')
        ax5.set_xlabel('Time (s)')
        ax5.set_ylabel('Real part')
        ax5.set_title('Signal Reconstruction Evolution')
        ax5.legend()
        ax5.grid(True, alpha=0.3)
        
        # 6. Method Comparison
        ax6 = fig.add_subplot(gs[3, :2])
        
        # Group results by method
        methods = {}
        for r in results:
            method = r.get('method', 'ekf')
            if method not in methods:
                methods[method] = []
            methods[method].append(abs((r['beat'] - (f2_true - f1_true)) * 1000))
        
        # Box plot of beat errors by method
        method_data = []
        method_labels = []
        for method, errors in methods.items():
            method_data.append(errors)
            method_labels.append(method.upper())
        
        if method_data:
            ax6.boxplot(method_data, labels=method_labels)
            ax6.set_ylabel('|Beat Error| (mHz)')
            ax6.set_title('Beat Error Distribution by Method')
            ax6.grid(True, alpha=0.3, axis='y')
        
        # 7. Summary Statistics
        ax7 = fig.add_subplot(gs[3, 2:])
        ax7.axis('off')
        
        summary_text = "Tracking Analysis Summary\n" + "="*45 + "\n\n"
        summary_text += f"True frequencies: f1={f1_true:.6f} Hz, f2={f2_true:.6f} Hz\n"
        summary_text += f"True beat: {(f2_true-f1_true)*1000:.3f} mHz\n"
        summary_text += f"True amplitudes: A1=1.0, A2=0.7\n\n"
        
        # Find best result overall
        beat_errors_abs = [abs((r['beat'] - (f2_true - f1_true)) * 1000) for r in results]
        best_idx = np.argmin(beat_errors_abs)
        
        summary_text += f"Best result: {results[best_idx]['label']}\n"
        summary_text += f"  Beat error: {beat_errors[best_idx]:+.3f} mHz\n"
        summary_text += f"  Method: {results[best_idx].get('method', 'ekf').upper()}\n\n"
        
        # Hybrid statistics
        hybrid_results = [r for r in results if r.get('method') == 'hybrid_ekf_pll']
        if hybrid_results:
            converged_count = sum(1 for r in hybrid_results 
                                if r['history'].get('handoff_converged', False))
            summary_text += f"Hybrid handoffs: {converged_count}/{len(hybrid_results)} converged\n"
            
            for r in hybrid_results:
                if r['history'].get('handoff_converged', False):
                    summary_text += f"  {r['label']}: σ(f1)={r['history']['std_f1_at_handoff']:.2f}, "
                    summary_text += f"σ(f2)={r['history']['std_f2_at_handoff']:.2f} mHz\n"
        
        ax7.text(0.05, 0.95, summary_text, transform=ax7.transAxes,
                fontsize=11, fontfamily='monospace', verticalalignment='top',
                bbox=dict(boxstyle='round', facecolor='lightblue', alpha=0.8))
        
        plt.suptitle('Hybrid EKF-PLL Tracking Analysis', fontsize=16)
        plt.tight_layout()
        plt.show()
        
        return fig


# Test the hybrid approach
def test_hybrid_ekf_pll():
    # Generate test signal with multiple frames
    fs_baseband = 960.0
    frame_duration = 0.3
    n_frames = 10
    total_duration = frame_duration * n_frames
    n_samples = int(fs_baseband * total_duration)
    t = np.arange(n_samples) / fs_baseband
    
    # True frequencies (at baseband)
    f1_true = 5.625480
    f2_true = 5.631480  # 6 mHz separation
    
    # Generate continuous two-tone signal
    signal_data = (np.exp(1j * 2 * np.pi * f1_true * t) + 
                   0.7 * np.exp(1j * 2 * np.pi * f2_true * t))
    
    # Add some noise
    noise_level = 0.01
    noise = noise_level * (np.random.randn(n_samples) + 1j * np.random.randn(n_samples)) / np.sqrt(2)
    signal_data += noise
    
    # Create analyzer
    analyzer = DualEKFAnalyzer(fs_baseband)
    
    # Compare methods
    print(f"Running hybrid comparison on {n_frames} coherent frames ({total_duration:.1f}s total)...")
    results = analyzer.run_hybrid_comparison(signal_data, f1_true, f2_true)
    
    # Print results
    print("\n" + "="*70)
    print("HYBRID EKF-PLL COMPARISON RESULTS")
    print("="*70)
    print(f"True: f1={f1_true:.6f} Hz, f2={f2_true:.6f} Hz, beat={6.000:.3f} mHz")
    print(f"Signal: {n_frames} frames, {total_duration:.1f}s total")
    print("\nMethod - Initialization -> Result:")
    
    for result in results:
        print(f"\n{result['label']}:")
        print(f"  Init: f1={result['f1_init']:.6f}, f2={result['f2_init']:.6f}")
        print(f"  Final: f1={result['f1']:.6f}, f2={result['f2']:.6f}")
        print(f"  Beat: {result['beat']*1000:.3f} mHz (error: {(result['beat']-(f2_true-f1_true))*1000:+.3f} mHz)")
        
        if result.get('method') == 'hybrid_ekf_pll' and result['history'].get('handoff_converged'):
            handoff_time = result['history']['handoff_sample'] / fs_baseband
            print(f"  Handoff: Converged at {handoff_time:.3f}s")
            print(f"  Uncertainties at handoff: σ(f1)={result['history']['std_f1_at_handoff']:.2f} mHz, "
                  f"σ(f2)={result['history']['std_f2_at_handoff']:.2f} mHz")
    
    # Visualize
    fig = analyzer.visualize_ekf_analysis(results, signal_data, f1_true, f2_true)
    
    # Test with different handoff fractions
    print("\n" + "="*60)
    print("TESTING DIFFERENT HANDOFF FRACTIONS")
    print("="*60)
    
    handoff_fractions = [0.1, 0.2, 0.3, 0.5]
    test_case = (f1_true - 0.010, f2_true + 0.010)  # Far from truth
    
    for fraction in handoff_fractions:
        result = analyzer.hybrid_ekf_pll_tracking(
            signal_data, test_case[0], test_case[1],
            ekf_duration_fraction=fraction
        )
        
        handoff_time = fraction * total_duration
        print(f"\nHandoff at {fraction*100:.0f}% ({handoff_time:.2f}s):")
        print(f"  Beat error: {(result['beat']-(f2_true-f1_true))*1000:+.3f} mHz")
        print(f"  Converged: {result['history'].get('handoff_converged', False)}")
        if result['history'].get('handoff_converged'):
            print(f"  Uncertainties: σ(f1)={result['history']['std_f1_at_handoff']:.2f} mHz, "
                  f"σ(f2)={result['history']['std_f2_at_handoff']:.2f} mHz")
    
    return analyzer, results


# Run the test
if __name__ == "__main__":
    analyzer, results = test_hybrid_ekf_pll()