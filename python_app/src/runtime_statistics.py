"""Small deterministic statistics shared by adaptive tuning and metrics reports."""

from typing import List


def percentile(values: List[float], q: float) -> float:
    seq = sorted(float(v) for v in (values or []) if float(v) >= 0.0)
    if not seq:
        return 0.0
    if q <= 0:
        return float(seq[0])
    if q >= 1:
        return float(seq[-1])
    idx = (len(seq) - 1) * q
    lo = int(idx)
    hi = min(len(seq) - 1, lo + 1)
    frac = idx - lo
    return float(seq[lo] * (1.0 - frac) + seq[hi] * frac)
