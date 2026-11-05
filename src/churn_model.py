"""Predict 14-day churn and evaluate how well the model ranks risk.

Model:      logistic regression (random forest trained as a benchmark)
Leakage:    trial_used_before_snapshot is replaced by the version rebuilt
            in SQL (sql/01_user_metrics.sql), which counts only trials
            that started before the snapshot. The provided column also
            counted later trials; the script reports the AUC both ways.
Split:      60% train / 20% validation / 20% untouched test, stratified
Evaluation: ROC-AUC, PR-AUC, and Top-K lift, i.e. if the team can only
            contact the riskiest X% of users, how many of them churn?

Run src/run_sql.py first, then (from the repo root):
    python src/churn_model.py
"""

from pathlib import Path

import duckdb
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import RandomForestClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, roc_auc_score, roc_curve
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

ROOT = Path(__file__).resolve().parents[1]
DATA_PATH = ROOT / "data" / "feature_table.csv"
DB_PATH = ROOT / "streaming.duckdb"
OUT_DIR = ROOT / "outputs" / "model"
FIG_DIR = ROOT / "outputs" / "figures"
RANDOM_STATE = 42

TARGET = "churn_label_14d"

# Features describe the user only up to the snapshot date.
NUMERIC_FEATURES = [
    "tenure_days",
    "active_days_7d",
    "listen_minutes_7d",
    "active_days_30d",
    "listen_minutes_30d",
    "sessions_30d",
    "avg_play_duration_sec_30d",
    "skip_rate_30d",
    "completion_rate_30d",
    "liked_songs_30d",
    "playlist_adds_30d",
    "search_events_30d",
    "ad_impressions_per_active_day",
    "ad_click_rate_30d",
    "ad_completion_rate_30d",
    "trial_used_before_snapshot",
    "payment_failed_30d",
]

CATEGORICAL_FEATURES = [
    "country",
    "region_tier",
    "age_group",
    "primary_device",
    "acquisition_channel",
    "student_eligible",
    "marketing_opt_in",
    "music_persona",
    "subscription_type",
    "lifecycle_stage",
    "top_genre_30d",
]

# Columns that describe the prediction window or an outcome. Using any of
# them would let the model "see the future" and inflate offline accuracy.
LEAKAGE_COLUMNS = {
    "churn_label_14d",      # the target
    "retained_14d",         # inverse of the target
    "listen_events_14d",    # activity inside the prediction window
    "renewal_success_14d",  # outcome inside the prediction window
    "paid_conversion_30d",  # outcome field that can overlap the window
    "paid_started_30d",
    "cancel_30d",
    "total_revenue_30d",    # revenue outcomes
    "ad_revenue_30d",
    "subscription_revenue_30d",
}

FEATURES = NUMERIC_FEATURES + CATEGORICAL_FEATURES


def check_no_leakage(features: list[str]) -> None:
    leaked = sorted(set(features) & LEAKAGE_COLUMNS)
    if leaked:
        raise ValueError(f"Leakage: outcome columns used as features: {leaked}")
    print("Leakage check passed: no prediction-window or outcome columns in features.")


def load_data() -> pd.DataFrame:
    """Feature table with the leaky trial flag swapped for the SQL rebuild."""
    df = pd.read_csv(DATA_PATH)
    with duckdb.connect(str(DB_PATH), read_only=True) as con:
        rebuilt = con.execute(
            "SELECT user_id, trial_used_before_snapshot FROM user_metrics"
        ).df().set_index("user_id")["trial_used_before_snapshot"]
    df["trial_used_before_snapshot_original"] = df["trial_used_before_snapshot"]
    df["trial_used_before_snapshot"] = df["user_id"].map(rebuilt).astype(int)
    changed = (df["trial_used_before_snapshot"] != df["trial_used_before_snapshot_original"]).sum()
    print(f"Replaced trial_used_before_snapshot: {changed:,} users had only post-snapshot trials.")
    return df


def build_preprocessor(drop_first: bool) -> ColumnTransformer:
    numeric = Pipeline([
        ("imputer", SimpleImputer(strategy="median")),
        ("scaler", StandardScaler()),
    ])
    categorical = Pipeline([
        ("imputer", SimpleImputer(strategy="most_frequent")),
        ("onehot", OneHotEncoder(handle_unknown="ignore", drop="first" if drop_first else None)),
    ])
    return ColumnTransformer([
        ("num", numeric, NUMERIC_FEATURES),
        ("cat", categorical, CATEGORICAL_FEATURES),
    ])


def top_k_lift(probability: np.ndarray, actual: np.ndarray, fractions: list[float]) -> pd.DataFrame:
    ranked = (
        pd.DataFrame({"probability": probability, "actual": actual})
        .sort_values("probability", ascending=False)
        .reset_index(drop=True)
    )
    baseline = ranked["actual"].mean()
    total_churners = ranked["actual"].sum()
    rows = []
    for fraction in fractions:
        n = int(np.ceil(len(ranked) * fraction))
        top = ranked.head(n)
        rows.append({
            "top_fraction": fraction,
            "users_targeted": n,
            "churn_rate_in_tier": top["actual"].mean(),
            "share_of_churners_captured": top["actual"].sum() / total_churners,
            "lift_vs_baseline": top["actual"].mean() / baseline,
        })
    return pd.DataFrame(rows)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    FIG_DIR.mkdir(parents=True, exist_ok=True)

    df = load_data()
    check_no_leakage(FEATURES)

    X = df[FEATURES].copy()
    y = df[TARGET].astype(int)

    # 60 / 20 / 20 split; the test set is only used once, at the end
    X_train_full, X_test, y_train_full, y_test = train_test_split(
        X, y, test_size=0.20, stratify=y, random_state=RANDOM_STATE
    )
    X_train, X_val, y_train, y_val = train_test_split(
        X_train_full, y_train_full, test_size=0.25, stratify=y_train_full, random_state=RANDOM_STATE
    )
    print(f"Train {len(X_train):,} | Validation {len(X_val):,} | Test {len(X_test):,}")
    print(f"Baseline 14-day churn rate: {y.mean():.2%}")

    models = {
        "logistic_regression": Pipeline([
            ("preprocess", build_preprocessor(drop_first=True)),
            ("model", LogisticRegression(max_iter=2000, C=1.0, solver="liblinear", random_state=RANDOM_STATE)),
        ]),
        "random_forest_benchmark": Pipeline([
            ("preprocess", build_preprocessor(drop_first=False)),
            ("model", RandomForestClassifier(
                n_estimators=120, max_depth=10, min_samples_leaf=20,
                max_features="sqrt", random_state=RANDOM_STATE, n_jobs=1,
            )),
        ]),
    }

    metric_rows = []
    for name, model in models.items():
        model.fit(X_train, y_train)
        for split, X_s, y_s in [("validation", X_val, y_val), ("test", X_test, y_test)]:
            p = model.predict_proba(X_s)[:, 1]
            metric_rows.append({
                "model": name,
                "split": split,
                "roc_auc": roc_auc_score(y_s, p),
                "pr_auc": average_precision_score(y_s, p),
            })
    metrics = pd.DataFrame(metric_rows)
    metrics.to_csv(OUT_DIR / "model_metrics.csv", index=False)
    print("\nRanking performance:")
    print(metrics.round(4).to_string(index=False))

    # Logistic regression is the selected model: similar AUC to the random
    # forest, but easier to explain, deploy, and monitor.
    lr = models["logistic_regression"]
    test_prob = lr.predict_proba(X_test)[:, 1]

    # Leakage sensitivity: same model, same split, original (leaky) trial flag
    X_leaky = df[FEATURES].copy()
    X_leaky["trial_used_before_snapshot"] = df["trial_used_before_snapshot_original"]
    leaky_model = Pipeline([
        ("preprocess", build_preprocessor(drop_first=True)),
        ("model", LogisticRegression(max_iter=2000, C=1.0, solver="liblinear", random_state=RANDOM_STATE)),
    ]).fit(X_leaky.loc[X_train.index], y_train)
    sensitivity = pd.DataFrame([
        {"trial_flag": "rebuilt (pre-snapshot only)", "test_roc_auc": roc_auc_score(y_test, test_prob)},
        {"trial_flag": "original (includes post-snapshot trials)",
         "test_roc_auc": roc_auc_score(y_test, leaky_model.predict_proba(X_leaky.loc[X_test.index])[:, 1])},
    ])
    sensitivity.to_csv(OUT_DIR / "leakage_sensitivity.csv", index=False)
    print("\nLeakage sensitivity (logistic regression, test set):")
    print(sensitivity.round(4).to_string(index=False))

    lift = top_k_lift(test_prob, y_test.to_numpy(), [0.05, 0.10, 0.20, 0.30])
    lift.to_csv(OUT_DIR / "topk_lift.csv", index=False)
    print("\nTop-K lift on the test set:")
    print(lift.round(4).to_string(index=False))

    deciles = pd.DataFrame({"actual": y_test.to_numpy(), "predicted": test_prob})
    deciles["risk_decile"] = pd.qcut(deciles["predicted"], q=10, labels=[f"D{i}" for i in range(1, 11)])
    decile_summary = (
        deciles.groupby("risk_decile", observed=True)
        .agg(users=("actual", "size"), avg_predicted=("predicted", "mean"), actual_churn_rate=("actual", "mean"))
        .reset_index()
    )
    decile_summary.to_csv(OUT_DIR / "risk_deciles.csv", index=False)

    coef = pd.DataFrame({
        "feature": lr.named_steps["preprocess"].get_feature_names_out(),
        "coefficient": lr.named_steps["model"].coef_[0],
    })
    coef["odds_ratio"] = np.exp(coef["coefficient"])
    coef.sort_values("coefficient", ascending=False).to_csv(OUT_DIR / "lr_coefficients.csv", index=False)

    pd.DataFrame({
        "user_id": df.loc[X_test.index, "user_id"].to_numpy(),
        "actual_churn": y_test.to_numpy(),
        "churn_score": test_prob,
    }).to_csv(OUT_DIR / "test_predictions.csv", index=False)

    # Figures for the README
    fpr, tpr, _ = roc_curve(y_test, test_prob)
    plt.figure(figsize=(5, 5))
    plt.plot(fpr, tpr, label=f"Logistic regression (AUC = {roc_auc_score(y_test, test_prob):.2f})")
    plt.plot([0, 1], [0, 1], linestyle="--", linewidth=1, label="Random")
    plt.xlabel("False positive rate")
    plt.ylabel("True positive rate")
    plt.title("ROC Curve, Test Set")
    plt.legend(loc="lower right")
    plt.tight_layout()
    plt.savefig(FIG_DIR / "roc_curve.png", dpi=150)
    plt.close()

    plt.figure(figsize=(7, 4))
    x = decile_summary["risk_decile"].astype(str)
    plt.plot(x, decile_summary["avg_predicted"] * 100, marker="o", label="Predicted")
    plt.plot(x, decile_summary["actual_churn_rate"] * 100, marker="o", label="Actual")
    plt.ylabel("14-day churn rate (%)")
    plt.xlabel("Risk decile (D10 = highest risk)")
    plt.title("Predicted vs. Actual Churn by Risk Decile, Test Set")
    plt.legend()
    plt.tight_layout()
    plt.savefig(FIG_DIR / "risk_deciles.png", dpi=150)
    plt.close()

    top20 = lift.loc[lift["top_fraction"] == 0.20].iloc[0]
    print(
        f"\nSummary: test ROC-AUC {roc_auc_score(y_test, test_prob):.2f}; "
        f"top-20% risk tier churned at {top20['churn_rate_in_tier']:.1%} "
        f"({top20['lift_vs_baseline']:.2f}x the {y_test.mean():.1%} baseline)."
    )


if __name__ == "__main__":
    main()
