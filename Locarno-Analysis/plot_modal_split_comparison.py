#!/usr/bin/env python3
"""Visualize the percentage-only MATSim/reference comparison.

Run AFTER compare_modal_splits.py from locarno_ETH_Model:

    python plot_modal_split_comparison.py \
        --summary modal_split_comparison/modal_split_summary.csv

Creates three PNGs inside modal_split_comparison/charts/:
    comparison_overview.png          mean absolute percentage-point difference
    grouped_mode_errors.png          per-mode differences for REV/Cintura table
    municipal_mode_errors.png        per-mode differences for REV municipalities

Uses percentages only. The 'n' columns are NOT used to calculate scores.
The script uses the same inclusion/exclusion rules already applied by
compare_modal_splits.py when it produced modal_split_summary.csv.
"""

from __future__ import annotations

import argparse
import csv
import math
import warnings
from pathlib import Path

import matplotlib
matplotlib.use("Agg")  # works on a headless HPC login/compute node
import matplotlib.pyplot as plt
import numpy as np

TABLES = ("grouped", "municipal")
MODES = ("Walk", "Bicycle", "Car", "Public transport")
OVERALL = "ALL COMPARABLE MODES"
SCORE = "unweighted_mean_absolute_difference_pp"


def numeric(value: str) -> float:
    text = str(value or "").strip().replace(" ", "").replace(",", ".")
    if not text:
        return float("nan")
    val = float(text)
    if val < 0 or not math.isfinite(val):
        raise ValueError(f"Invalid mean absolute difference: {value!r}")
    return val


def load_summary(path: Path):
    if not path.is_file():
        raise FileNotFoundError(f"Summary not found: {path}")
    with path.open(encoding="utf-8-sig", newline="") as handle:
        first = handle.readline()
        delimiter = ";" if first.count(";") > first.count(",") else ","
        handle.seek(0)
        rows = list(csv.DictReader(handle, delimiter=delimiter))
    required = {"formulation", "table", "mode", SCORE, "compared_OD_mode_cells"}
    if not rows or not required.issubset(rows[0]):
        raise ValueError(
            f"Expected the latest modal_split_summary.csv with columns: {sorted(required)}. "
            "Rerun the updated compare_modal_splits.py if necessary."
        )
    cases = list(dict.fromkeys(row["formulation"].strip() for row in rows))
    if not cases or any(not x for x in cases):
        raise ValueError("No valid formulations found")
    data = {}
    for row in rows:
        case = row["formulation"].strip()
        table = row["table"].strip().lower()
        mode = row["mode"].strip()
        if table not in TABLES or mode not in (*MODES, OVERALL):
            continue
        key = (case, table, mode)
        if key in data:
            raise ValueError(f"Repeated formulation/table/mode in summary: {key}")
        data[key] = (numeric(row[SCORE]), int(row["compared_OD_mode_cells"]))
    # Warn if one formulation was compared using a different set of OD/mode cells.
    # With varying coverage, differences in the plotted score may be due to the sample.
    for table in TABLES:
        mode = OVERALL
        counts = {case: data.get((case, table, mode), (float("nan"), 0))[1] for case in cases}
        if len(set(counts.values())) > 1:
            warnings.warn(f"{table}: compared OD/mode cell counts differ across formulations: {counts}. "
                          "Inspect missing/zero-trip cells before interpreting the plot.")
    return cases, data


def get(data, case, table, mode):
    return data.get((case, table, mode), (float("nan"), 0))


def plot_overview(cases, data, path):
    # The geographic/mode scopes differ: DO NOT merge the two table scores.
    x = np.arange(len(cases), dtype=float)
    width = 0.37
    fig, ax = plt.subplots(figsize=(max(9, 1.45 * len(cases) + 4), 6))
    legend = {"grouped": "REV / Cintura",
              "municipal": "REV municipalities"}
    for offset, table in [(-width / 2, "grouped"), (width / 2, "municipal")]:
        heights = np.array([get(data, case, table, OVERALL)[0] for case in cases])
        bars = ax.bar(x + offset, np.nan_to_num(heights, nan=0), width,
                      label=legend[table])
        for rect, value in zip(bars, heights):
            if math.isfinite(value):
                ax.annotate(f"{value:.2f}", (rect.get_x() + rect.get_width()/2,
                            rect.get_height()), xytext=(0, 4),
                            textcoords="offset points", ha="center", va="bottom", fontsize=9)
            else:
                rect.set_alpha(0.15)
                ax.text(rect.get_x() + rect.get_width()/2, 0, "n/a",
                        ha="center", va="bottom", fontsize=9)
    ax.set_xticks(x, cases)
    ax.set_ylabel("Mean absolute modal-share difference (percentage points)")
    ax.set_title("Modal split compared with the reference (lower = closer)")
    ax.legend(loc="upper right")
    ax.grid(axis="y", alpha=0.25)
    ax.set_axisbelow(True)
    ax.set_ylim(bottom=0)
    fig.text(0.5, 0.015,
             "Scores are unweighted averages of percentage-point differences; each reference table is evaluated separately.",
             ha="center", fontsize=9)
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    fig.savefig(path, dpi=200, bbox_inches="tight")
    plt.close(fig)


def plot_mode_heatmap(cases, data, table, path):
    modes = [m for m in MODES if any(math.isfinite(get(data, c, table, m)[0]) for c in cases)]
    if not modes:
        print(f"  Skipped {path.name}: no comparable mode-level values")
        return
    matrix = np.array([[get(data, case, table, mode)[0] for mode in modes]
                       for case in cases], dtype=float)
    fig, ax = plt.subplots(figsize=(max(8, len(modes)*1.7+2), max(3.5, len(cases)*0.62+2)))
    plot_data = np.ma.masked_invalid(matrix)
    cmap = plt.get_cmap("YlOrRd").copy()
    cmap.set_bad(color="lightgray")
    maximum = float(np.nanmax(matrix)) if np.isfinite(matrix).any() else 1.0
    image = ax.imshow(plot_data, cmap=cmap, vmin=0, vmax=max(maximum, 0.1), aspect="auto")
    ax.set_xticks(np.arange(len(modes)), modes)
    ax.set_yticks(np.arange(len(cases)), cases)
    ax.tick_params(axis="x", labelrotation=20)
    ax.set_title("REV / Cintura: errors by transport mode" if table == "grouped"
                 else "REV municipalities: errors by transport mode")
    for i in range(len(cases)):
        for j in range(len(modes)):
            val = matrix[i, j]
            label = f"{val:.2f}" if math.isfinite(val) else "n/a"
            ax.text(j, i, label, ha="center", va="center", fontsize=10,
                    color="white" if math.isfinite(val) and maximum > 0 and val / maximum > 0.7 else "black")
    ax.set_xticks(np.arange(-0.5, len(modes), 1), minor=True)
    ax.set_yticks(np.arange(-0.5, len(cases), 1), minor=True)
    ax.grid(which="minor", color="white", linewidth=1.5)
    ax.tick_params(which="minor", bottom=False, left=False)
    colorbar = fig.colorbar(image, ax=ax, fraction=0.05, pad=0.04)
    colorbar.set_label("Mean absolute difference (percentage points)")
    fig.tight_layout()
    fig.savefig(path, dpi=200, bbox_inches="tight")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--summary", type=Path, default=Path("modal_split_comparison/modal_split_summary.csv"))
    parser.add_argument("--output-dir", type=Path,
                        help="Directory for PNGs (default: charts/ next to the summary)")
    args = parser.parse_args()
    cases, data = load_summary(args.summary)
    output_dir = args.output_dir or args.summary.parent / "charts"
    output_dir.mkdir(parents=True, exist_ok=True)
    overview = output_dir / "comparison_overview.png"
    plot_overview(cases, data, overview)
    print(f"Saved {overview}")
    for table in TABLES:
        filename = output_dir / f"{table}_mode_errors.png"
        plot_mode_heatmap(cases, data, table, filename)
        if filename.is_file():
            print(f"Saved {filename}")
    print("Reminder: reference data are commuting-only, so all-trip cases have a different purpose scope.")


if __name__ == "__main__":
    main()
