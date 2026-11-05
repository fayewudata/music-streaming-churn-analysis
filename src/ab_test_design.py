"""Design an A/B test of paywall messaging.

Step 1  Check whether the observed paywall-vs-email conversion gap is
        larger than noise. This comparison is observational: users who
        start a trial from the paywall chose to, so the gap can reflect
        intent as well as the surface. That is why it motivates an
        experiment instead of a rollout.
Step 2  Size the experiment for two eligibility scopes (paywall-origin
        trials only vs. all trial starters): users per arm and weeks of
        traffic needed for a given lift, and the smallest lift each scope
        can detect in a fixed test length.
Step 3  Helper functions to analyze the test once results exist:
        a sample-ratio-mismatch check and a two-proportion comparison.

Run src/run_sql.py first, then (from the repo root):
    python src/ab_test_design.py
"""

from math import ceil, sqrt
from pathlib import Path

import pandas as pd
from scipy.stats import chi2, norm

ROOT = Path(__file__).resolve().parents[1]
SQL_OUT = ROOT / "outputs" / "sql" / "rpt_trial_conversion_by_touchpoint.csv"
OUT_DIR = ROOT / "outputs" / "ab_test"

ALPHA = 0.05                       # two-sided significance level
POWER = 0.80                       # chance of detecting a true effect of size MDE
MDES = [0.01, 0.02, 0.03, 0.04]    # minimum detectable effects, absolute (1-4 points)
TEST_WEEKS = [8, 12, 26]           # candidate enrollment lengths
TRAFFIC_SHARE = 1.0                # share of eligible users enrolled in the test


def compare_proportions(x1: int, n1: int, x2: int, n2: int, alpha: float = ALPHA) -> dict:
    """Two-proportion z-test (pooled SE for the test, unpooled SE for the CI)."""
    p1, p2 = x1 / n1, x2 / n2
    diff = p1 - p2
    p_pool = (x1 + x2) / (n1 + n2)
    se_pool = sqrt(p_pool * (1 - p_pool) * (1 / n1 + 1 / n2))
    z = diff / se_pool
    p_value = 2 * (1 - norm.cdf(abs(z)))
    se_diff = sqrt(p1 * (1 - p1) / n1 + p2 * (1 - p2) / n2)
    z_crit = norm.ppf(1 - alpha / 2)
    return {
        "rate_a": p1,
        "rate_b": p2,
        "diff_pct_points": diff * 100,
        "ci_low_pct_points": (diff - z_crit * se_diff) * 100,
        "ci_high_pct_points": (diff + z_crit * se_diff) * 100,
        "z": z,
        "p_value": p_value,
    }


def sample_size_per_arm(p_control: float, mde: float, alpha: float = ALPHA, power: float = POWER) -> int:
    """Users per arm to detect an absolute lift of `mde` over `p_control`."""
    p_treat = p_control + mde
    p_bar = (p_control + p_treat) / 2
    z_alpha = norm.ppf(1 - alpha / 2)
    z_beta = norm.ppf(power)
    numerator = (
        z_alpha * sqrt(2 * p_bar * (1 - p_bar))
        + z_beta * sqrt(p_control * (1 - p_control) + p_treat * (1 - p_treat))
    ) ** 2
    return ceil(numerator / mde ** 2)


def detectable_effect(p_control: float, n_per_arm: int, alpha: float = ALPHA, power: float = POWER) -> float:
    """Smallest absolute lift detectable with `n_per_arm` users per arm (binary search)."""
    lo, hi = 1e-4, 1 - p_control - 1e-4
    for _ in range(60):
        mid = (lo + hi) / 2
        if sample_size_per_arm(p_control, mid, alpha, power) <= n_per_arm:
            hi = mid
        else:
            lo = mid
    return hi


def srm_check(n_control: int, n_treatment: int, expected_treatment_share: float = 0.5) -> float:
    """Sample ratio mismatch: p-value that the observed split matches the plan.
    A p-value below 0.001 usually means broken assignment or logging, and
    the results should not be trusted until that is fixed."""
    total = n_control + n_treatment
    expected = [total * (1 - expected_treatment_share), total * expected_treatment_share]
    observed = [n_control, n_treatment]
    stat = sum((o - e) ** 2 / e for o, e in zip(observed, expected))
    return 1 - chi2.cdf(stat, df=1)


def analyze_experiment(conv_control: int, n_control: int, conv_treatment: int, n_treatment: int) -> dict:
    """Read out the experiment once the 30-day conversion window has closed."""
    result = compare_proportions(conv_treatment, n_treatment, conv_control, n_control)
    result["srm_p_value"] = srm_check(n_control, n_treatment)
    result["relative_lift_pct"] = (result["rate_a"] / result["rate_b"] - 1) * 100
    return result


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    by_touchpoint = pd.read_csv(SQL_OUT).set_index("trial_touchpoint")
    paywall, email = by_touchpoint.loc["paywall"], by_touchpoint.loc["email"]

    # Step 1: observed gap
    obs = compare_proportions(
        int(paywall["converted"]), int(paywall["trials"]),
        int(email["converted"]), int(email["trials"]),
    )
    pd.DataFrame([{"comparison": "paywall_vs_email", **obs}]).to_csv(
        OUT_DIR / "observed_gap.csv", index=False
    )
    print("Step 1: observed 30-day trial-to-paid conversion (mature trials)")
    print(f"  Paywall-origin: {obs['rate_a']:.2%} of {int(paywall['trials']):,} trials")
    print(f"  Email-origin:   {obs['rate_b']:.2%} of {int(email['trials']):,} trials")
    print(
        f"  Gap: {obs['diff_pct_points']:+.2f} pts "
        f"(95% CI {obs['ci_low_pct_points']:+.2f} to {obs['ci_high_pct_points']:+.2f}), "
        f"p = {obs['p_value']:.4f}"
    )
    print("  Note: observational. Paywall users self-select, so this motivates a test, not a rollout.")

    # Step 2: power analysis for two eligibility scopes
    scopes = {
        "paywall_trials_only": {
            "baseline": obs["rate_a"],
            "weekly": float(paywall["trials_per_week"]) * TRAFFIC_SHARE,
        },
        "all_trial_starters": {
            "baseline": by_touchpoint["converted"].sum() / by_touchpoint["trials"].sum(),
            "weekly": float(by_touchpoint["trials_per_week"].sum()) * TRAFFIC_SHARE,
        },
    }

    size_rows, mde_rows = [], []
    for scope, cfg in scopes.items():
        for mde in MDES:
            n = sample_size_per_arm(cfg["baseline"], mde)
            size_rows.append({
                "scope": scope,
                "baseline_conversion": cfg["baseline"],
                "eligible_per_week": cfg["weekly"],
                "mde_pct_points": mde * 100,
                "users_per_arm": n,
                "weeks_to_enroll": 2 * n / cfg["weekly"],
            })
        for weeks in TEST_WEEKS:
            n_per_arm = int(cfg["weekly"] * weeks / 2)
            mde_rows.append({
                "scope": scope,
                "test_weeks": weeks,
                "users_per_arm": n_per_arm,
                "detectable_lift_pct_points": detectable_effect(cfg["baseline"], n_per_arm) * 100,
            })

    size_table = pd.DataFrame(size_rows)
    mde_table = pd.DataFrame(mde_rows)
    size_table.to_csv(OUT_DIR / "power_analysis.csv", index=False)
    mde_table.to_csv(OUT_DIR / "detectable_lift_by_duration.csv", index=False)

    print(f"\nStep 2: sample size (alpha = {ALPHA}, power = {POWER:.0%}, 50/50 split)")
    print(size_table.round(2).to_string(index=False))
    print("\nSmallest detectable lift for a fixed enrollment length:")
    print(mde_table.round(2).to_string(index=False))
    print("  Add 30 days after enrollment ends so every user's conversion window closes.")

if __name__ == "__main__":
    main()
