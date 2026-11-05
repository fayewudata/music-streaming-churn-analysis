"""Run the SQL pipeline in order and export every rpt_* view to outputs/sql/.

Usage (from the repo root):
    python src/run_sql.py
"""

import os
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "sql"
OUT_DIR = ROOT / "outputs" / "sql"
DB_PATH = ROOT / "streaming.duckdb"


def main() -> None:
    # SQL files use paths relative to the repo root (e.g. 'data/users.csv')
    os.chdir(ROOT)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(DB_PATH))

    for sql_file in sorted(SQL_DIR.glob("*.sql")):
        print(f"Running {sql_file.name}")
        con.execute(sql_file.read_text(encoding="utf-8"))

    reports = [
        row[0]
        for row in con.execute(
            """
            SELECT table_name
            FROM information_schema.tables
            WHERE table_name LIKE 'rpt_%'
            ORDER BY table_name
            """
        ).fetchall()
    ]

    for name in reports:
        df = con.execute(f"SELECT * FROM {name}").df()
        df.to_csv(OUT_DIR / f"{name}.csv", index=False)
        print(f"\n=== {name} ===")
        print(df.to_string(index=False))

    con.close()
    print(f"\nExported {len(reports)} reports to {OUT_DIR.relative_to(ROOT)}/")


if __name__ == "__main__":
    main()
