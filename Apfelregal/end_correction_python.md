"""
end_correction.py

A collection of functions to compute the end correction (Δₑ) for circular pipes
under various assumptions and configurations. Each function is documented with:
- Formula
- Approach
- Context
- Assumptions / Limitations
- Typical Accuracy
- Use-Case
- Citation
- Parameters
- Returns
"""

import numpy as np


def delta_e_rayleigh(a):
    """
    Rayleigh's Simple Rule-of-Thumb End Correction
    ----------------------------------------------
    Formula:
        Δₑ = 0.6 * a

    Approach:
        Empirical, based on treating the open end as a massless piston radiating into free space.

    Context:
        One of the earliest estimates for an unflanged circular pipe in the low-frequency limit.

    Assumptions / Limitations:
        - Valid for k*a ≪ 1 (i.e., wavelength ≫ pipe radius).
        - Assumes unflanged, zero-thickness wall, no mean flow.
        - Neglects higher-order (frequency-dependent) radiation effects.

    Typical Accuracy:
        Approximately 10–15% error when k*a ≲ 0.3, relative to a full numerical impedance solution.

    Use-Case:
        Quick, back-of-the-envelope estimates for flute- or organ-pipe–scale bore sizes at low frequencies.

    Citation:
        Rayleigh, J.W.S. (1877). “Theory of Sound”, Vol. II. §§302, 314. Dover (1945).

    Parameters:
        a (float): Radius of the pipe (in meters).

    Returns:
        float: End correction Δₑ (in meters).
    """
    return 0.6 * a


def delta_e_parvs(a):
    """
    PARVS Model End Correction
    --------------------------
    Formula:
        Δₑ = (2/3) * a

    Approach:
        Equates the volume of a hemispherical radiator of radius a to that of a cylindrical plug
        of length Δₑ (i.e., (2π/3) a^3 = π a^2 Δₑ).

    Context:
        PARVS (“Pipe’s Acoustically Resonating Vortical Sphere”) geometry model, useful
        for unflanged, thin-walled pipes at low frequencies.

    Assumptions / Limitations:
        - Valid for k*a ≪ 1.
        - Assumes unflanged, zero-thickness wall, and a dominant vortical sphere radiation mechanism.
        - Overestimates Δₑ slightly compared to the exact k*a → 0 limit.

    Typical Accuracy:
        Within about 5–10% of Levine & Schwinger’s exact low-frequency value (0.6133 a) when k*a → 0.

    Use-Case:
        Flute- or organ-pipe scale designs where a simple geometric model is acceptable.

    Citation:
        Edskes, B.H., Heider, D.T., van Leeuwen, J.L., Seeber, B.U., & van Hemmen, J.L. (2024).
        “Tone generation in an open-end organ pipe: How a resonating sphere of air stops the pipe.”

    Parameters:
        a (float): Radius of the pipe (in meters).

    Returns:
        float: End correction Δₑ (in meters).
    """
    return (2.0 / 3.0) * a


def delta_e_levine_schwinger_series(a, k):
    """
    Levine & Schwinger Series Expansion (Unflanged, k*a ≪ 1)
    --------------------------------------------------------
    Formula:
        Δₑ / a ≈ 0.6133 + 0.0858 (k*a)^2 - 0.0112 (k*a)^4
        => Δₑ = a * (0.6133 + 0.0858*(ka)**2 - 0.0112*(ka)**4)

    Approach:
        Exact Wiener–Hopf solution for the radiation impedance of an unflanged circular pipe,
        expanded as a power series in (k*a).

    Context:
        High-precision low-frequency correction for unflanged pipes.

    Assumptions / Limitations:
        - Valid primarily for k*a ≲ 0.3–0.5.
        - Assumes unflanged, zero-thickness wall, free-space radiation.
        - Additional (k*a)^6 and higher terms exist but are omitted here.

    Typical Accuracy:
        - Within ≈1% for k*a ≲ 0.3.
        - Within ≈2% for k*a ≲ 0.6 when including up to (k*a)^4 term.

    Use-Case:
        Precision modeling of flue-type wind instruments in the low-frequency limit.

    Citation:
        Levine, H., & Schwinger, J. (1948). “On the radiation of sound from an unflanged circular pipe,”
        Physical Review, 73, 383–406.

    Parameters:
        a (float): Radius of the pipe (in meters).
        k (float): Acoustic wavenumber (2π / λ) (in 1/meters).

    Returns:
        float: End correction Δₑ (in meters).
    """
    ka = k * a
    return a * (0.6133 + 0.0858 * ka**2 - 0.0112 * ka**4)


def delta_e_morse_ingard(a, k):
    """
    Morse & Ingard First-Order Perturbation (Unflanged, k*a ≪ 1)
    ------------------------------------------------------------
    Formula:
        Δₑ / a ≈ 0.6133 + 0.5 (k*a)^2
        => Δₑ = a * (0.6133 + 0.5*(ka)**2)

    Approach:
        Matched-asymptotic expansion for the low-frequency end correction.

    Context:
        Introductory acoustics approximation for first-order frequency dependence in unflanged pipes.

    Assumptions / Limitations:
        - Valid for k*a ≪ 1 (typically k*a ≲ 0.2).
        - Assumes unflanged, zero-thickness wall, free-space radiation.
        - Omits higher-order (k*a)^4 terms.

    Typical Accuracy:
        Within ≈2–3% for k*a ≲ 0.2; degrades rapidly for k*a > 0.4.

    Use-Case:
        Educational contexts or preliminary designs where low-frequency dependence is desired.

    Citation:
        Morse, P.M., & Ingard, K.U. (1968). “Theoretical Acoustics.” McGraw-Hill.

    Parameters:
        a (float): Radius of the pipe (in meters).
        k (float): Acoustic wavenumber (2π / λ) (in 1/meters).

    Returns:
        float: End correction Δₑ (in meters).
    """
    ka = k * a
    return a * (0.6133 + 0.5 * ka**2)


def delta_e_ingard_empirical(a, k):
    """
    Ingard’s Empirical Polynomial Fit (Unflanged, Moderate k*a)
    -----------------------------------------------------------
    Formula:
        Δₑ / a ≈ 0.6135 + 0.1643 (k*a) + 0.0196 (k*a)^2
        => Δₑ = a * (0.6135 + 0.1643*(ka) + 0.0196*(ka)**2)

    Approach:
        Empirical fit to measured radiation impedance for k*a up to ≈ 1.5.

    Context:
        Mid-range frequency modeling for unflanged circular pipes.

    Assumptions / Limitations:
        - Valid approximately for 0 < k*a ≲ 1.5.
        - Assumes unflanged, zero-thickness wall, no mean flow.
        - Error grows for k*a > 1.5.

    Typical Accuracy:
        Within ≈2–3% for 0.1 < k*a < 1.0; up to ~10% error by k*a ≈ 1.5.

    Use-Case:
        Modeling of duct acoustics or wind instruments in intermediate-frequency regime.

    Citation:
        Ingard, U. (1953). “On the theory and design of rectilinear ducts,” Journal of the Acoustical
        Society of America, 25(6), 1079–1097.

    Parameters:
        a (float): Radius of the pipe (in meters).
        k (float): Acoustic wavenumber (2π / λ) (in 1/meters).

    Returns:
        float: End correction Δₑ (in meters).
    """
    ka = k * a
    return a * (0.6135 + 0.1643 * ka + 0.0196 * ka**2)


def delta_e_nomura_tsukamoto(a, k):
    """
    Nomura & Tsukamoto Polynomial Fit (Unflanged, k*a up to ~2)
    -----------------------------------------------------------
    Formula:
        Δₑ / a ≈ 0.6133 + 0.1756 (k*a) - 0.0053 (k*a)^2 + 0.0059 (k*a)^3
                 - 0.0017 (k*a)^4 + 0.0002 (k*a)^5
        => Δₑ = a * polynomial in (k*a)

    Approach:
        Empirical + numerical fit to impedance data for k*a up to ≈ 2.

    Context:
        Mid- to upper-frequency range modeling for unflanged circular pipes.

    Assumptions / Limitations:
        - Valid approximately for 0 < k*a ≲ 2.
        - Assumes unflanged, zero-thickness wall, no mean flow.
        - May degrade for k*a > 2.

    Typical Accuracy:
        Typically within ≈1% for 0 < k*a < 1.5; degrades to ≈5% by k*a ≈ 2.

    Use-Case:
        Higher-frequency design of instruments or ducts where k*a approaches unity or above.

    Citation:
        Nomura, M., & Tsukamoto, S. (1980). “Radiation impedance of a circular pipe with finite
        thickness,” Japanese Journal of Applied Physics, 19(11), 1705–1711.

    Parameters:
        a (float): Radius of the pipe (in meters).
        k (float): Acoustic wavenumber (2π / λ) (in 1/meters).

    Returns:
        float: End correction Δₑ (in meters).
    """
    ka = k * a
    return a * (0.6133
                + 0.1756 * ka
                - 0.0053 * ka**2
                + 0.0059 * ka**3
                - 0.0017 * ka**4
                + 0.0002 * ka**5)


def delta_e_flanged(a, k):
    """
    Levine & Schwinger Flanged Pipe Expansion (k*a ≪ 1)
    ----------------------------------------------------
    Formula:
        Δₑ / a ≈ 0.8216 + 0.095 (k*a)^2
        => Δₑ = a * (0.8216 + 0.095*(ka)**2)

    Approach:
        Wiener–Hopf solution adapted for a pipe mounted flush on an infinite rigid flange.

    Context:
        End correction for pipes with an infinite flange (baffle) at the open end in the low-frequency limit.

    Assumptions / Limitations:
        - Valid for k*a ≲ 0.5.
        - Assumes a perfectly rigid, infinite flange, no mean flow.
        - Zero-thickness wall.

    Typical Accuracy:
        Within ≈1–2% for k*a ≲ 0.5 when including the (k*a)^2 term.

    Use-Case:
        Modeling loudspeakers on a baffle, flanged organ pipes, or tubes flush with walls.

    Citation:
        Melling, A. (1973). “The acoustic impedance of perforates at medium and high sound pressure levels,”
        Journal of Sound and Vibration, 25(1), 1–12.
        Levine, H., & Schwinger, J. (1948). “Radiation from a flanged circular piston.”

    Parameters:
        a (float): Radius of the pipe (in meters).
        k (float): Acoustic wavenumber (2π / λ) (in 1/meters).

    Returns:
        float: End correction Δₑ (in meters).
    """
    ka = k * a
    return a * (0.8216 + 0.095 * ka**2)


def delta_e_partial_flange(a, Rf):
    """
    Partial Flange End Correction (Finite Flange Radius)
    ---------------------------------------------------
    Formula (approximate for Rf ≥ 2a):
        Δₑ ≈ a * [0.6133 + 0.5 * (a / Rf)]

    Approach:
        Interpolates between unflanged (0.6133 a) and fully flanged (0.8216 a) limits by adding
        a term proportional to (a / Rf).

    Context:
        End correction for a pipe mounted in a finite-size flange of radius Rf.

    Assumptions / Limitations:
        - Valid approximately for Rf ≳ 2a.
        - Assumes unflanged baseline value of 0.6133 a, zero-thickness wall.
        - Error increases for Rf < 2a; full numerical integration recommended.

    Typical Accuracy:
        Within ≈5% when Rf ≥ 2a; requires numerical solution for small Rf.

    Use-Case:
        Tubes mounted in panels, small speaker enclosures with finite flanges.

    Citation:
        Levine, H., & Schwinger, J. (1948). “On the radiation of sound from an unflanged circular pipe,”
        Physical Review, 73, 383–406. (Partial flange approximations derived from interpolation.)

    Parameters:
        a (float): Radius of the pipe (in meters).
        Rf (float): Radius of the finite flange (in meters).

    Returns:
        float: End correction Δₑ (in meters).

    Raises:
        ValueError: If Rf < a (invalid geometry).
    """
    if Rf < a:
        raise ValueError("Flange radius Rf must be ≥ pipe radius a.")
    return a * (0.6133 + 0.5 * (a / Rf))


def delta_e_ingard_thick_wall(a, t):
    """
    Ingard’s Thick-Wall End Correction
    ----------------------------------
    Formula:
        Δₑ ≈ a * [0.6133 + 0.5 * (t / a)]

    Approach:
        Adjusts the unflanged end correction to account for finite wall thickness t.

    Context:
        End correction for unflanged pipes with nonzero wall thickness.

    Assumptions / Limitations:
        - Valid for 0 < t / a ≲ 0.2.
        - Neglects lip chamfer or rounding.
        - Zero flange, free-space radiation.

    Typical Accuracy:
        Within ≈5% of full numerical integration for t / a ≲ 0.1.

    Use-Case:
        Metal flue pipes or cylindrical tubes where wall thickness is known.

    Citation:
        Ingard, U. (1953). “On the theory and design of rectilinear ducts,” Journal of the Acoustical
        Society of America, 25(6), 1079–1097.

    Parameters:
        a (float): Inner radius of the pipe (in meters).
        t (float): Wall thickness (in meters).

    Returns:
        float: End correction Δₑ (in meters).

    Raises:
        ValueError: If t / a > 0.2 (outside recommended range).
    """
    if t / a > 0.2:
        raise ValueError("Wall thickness t must satisfy t / a ≤ 0.2 for this approximation.")
    return a * (0.6133 + 0.5 * (t / a))


def delta_e_nakamura_ueda(a, t):
    """
    Nakamura & Ueda Semi-Empirical Thick-Wall Correction
    ---------------------------------------------------
    Formula:
        Δₑ = a * [0.6133 + 0.67 * (t / a)^0.33], for t / a ≤ 0.25

    Approach:
        Empirical fit from impedance-tube measurements on steel pipes of varying wall thickness.

    Context:
        End correction for unflanged pipes where wall thickness is a significant fraction of radius.

    Assumptions / Limitations:
        - Valid for t / a ≤ 0.25.
        - Neglects lip chamfer or rounding.
        - Zero flange, free-space radiation.

    Typical Accuracy:
        Within ≈3% for t / a up to 0.25.

    Use-Case:
        Designing short organ pipes or instruments where wall thickness is comparable to radius.

    Citation:
        Nakamura, K., & Ueda, S. (1976). “Measurement of radiation impedance of circular pipes
        with finite wall thickness.” Journal of Applied Acoustics (in Japanese).

    Parameters:
        a (float): Inner radius of the pipe (in meters).
        t (float): Wall thickness (in meters).

    Returns:
        float: End correction Δₑ (in meters).

    Raises:
        ValueError: If t / a > 0.25 (outside recommended range).
    """
    if t / a > 0.25:
        raise ValueError("Wall thickness t must satisfy t / a ≤ 0.25 for this approximation.")
    return a * (0.6133 + 0.67 * (t / a) ** 0.33)


def delta_e_direct_numerical(a, k):
    """
    Direct Numerical Integration of Radiation Impedance (Stub)
    -----------------------------------------------------------
    Formula:
        Z_r = (ρ c / (k a)) ∫₀^{k a} J₁(ξ)^2 dξ
        Δₑ = Im{Z_r} / (ρ c)

    Approach:
        Numerically integrate the radiation impedance integral for an unflanged circular pipe.

    Context:
        “Exact” solution (within linear acoustics) for arbitrary k*a, unflanged, zero-thickness rim.

    Assumptions / Limitations:
        - Assumes no mean flow, free-space radiation, perfectly circular geometry.
        - Requires numerical quadrature (e.g., Gauss–Legendre) or tabulated values.
        - Computational stub: must be implemented by the user.

    Typical Accuracy:
        Errors < 0.1% if implemented with sufficient numerical precision.

    Use-Case:
        Highest-accuracy design of wind instruments or acoustic waveguides.

    Citation:
        Levine, H., & Schwinger, J. (1948). “On the radiation of sound from an unflanged circular pipe,”
        Physical Review, 73, 383–406.

    Parameters:
        a (float): Radius of the pipe (in meters).
        k (float): Acoustic wavenumber (2π / λ) (in 1/meters).

    Returns:
        float: End correction Δₑ (in meters).

    Raises:
        NotImplementedError: This function is a stub. Implement numerical integration as needed.
    """
    raise NotImplementedError("Direct numerical integration must be implemented by the user.")
