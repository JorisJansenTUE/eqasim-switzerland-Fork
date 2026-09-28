#!/usr/bin/env python3
"""Add reference modal-share differences to MATSim OD CSVs (standard library only).

Run from locarno_ETH_Model, with the two reference CSVs beside this script:

python compare_modal_splits.py \
  --case "All trips" simulation_output_long/mode_choice_rev_cintura_other.csv simulation_output_long/mode_choice_od_table.csv \
  --case "Home" simulation_output_long/mode_choice_rev_cintura_other_Home.csv simulation_output_long/mode_choice_od_table_Home.csv \
  --case "HorW" simulation_output_long/mode_choice_rev_cintura_other_HorW.csv simulation_output_long/mode_choice_od_table_HorW.csv \
  --case "hw" simulation_output_long/mode_choice_rev_cintura_other_hw.csv simulation_output_long/mode_choice_od_table_hw.csv \
  --output-dir modal_split_comparison

For each case, makes annotated COPIES in output-dir/<case name>/, with columns
REV_n;REV_%;REV_%Diff;Cintura REV_n;Cintura REV_%;Cintura REV_%Diff;...
(or the corresponding municipality names). Existing n/% values are retained.
%Diff is the SIGNED percentage-POINT difference: model % minus reference %.
It is not a relative percentage difference; e.g. 16% - 12% = +4 pp.

The optional summary compares percentages ONLY, using an UNWEIGHTED mean
absolute percentage-point difference; neither simulation nor reference n is
used as a weight. The n columns are never compared. Zero-denominator OD
cells are left blank rather than treating an undefined share as 0%.

Caveats: the reference is 2012-2016 commuting; model cases may be all-purpose.
Model Other need not match reference Other (Swiss municipalities only), and
municipality-reference PT is bus-only whereas simulation PT is all PT.
All cells receive visible %Diff annotations where defined; by default those
non-equivalent cells are excluded from the optional summary. Opt in using
--include-other-proxy and/or --include-municipal-pt-proxy.
"""

from __future__ import annotations

import argparse
import csv
import math
import re
import sys
from collections import defaultdict
from pathlib import Path

GROUPS = ("REV", "Cintura REV", "Other")
MUNICIPALITIES = ("Ascona", "Locarno", "Minusio", "Muralto")
MODES = ("Walk", "Bicycle", "Car", "Public transport")


def normalized(value: str) -> str:
    return " ".join(str(value).casefold().strip().replace("_", " ").split())


def place(value: str, table_type: str) -> str:
    val = normalized(value)
    if table_type == "grouped":
        return {
            "rev": "REV", "cintura rev": "Cintura REV", "other": "Other",
            "other municipality": "Other", "other municipality (ch)": "Other",
            "total": "Total",
        }.get(val, value.strip())
    return next((v for v in (*MUNICIPALITIES, "Total") if normalized(v) == val), value.strip())


def mode_name(value: str) -> str:
    return {
        "public transport (bus only)": "Public transport",
        "public transport": "Public transport", "walk": "Walk", "bicycle": "Bicycle",
        "car": "Car", "total": "Total",
    }.get(normalized(value), value.strip())


def number(value: str, file: Path, label: str) -> float | None:
    value = str(value or "").strip().replace("%", "").replace("\u00a0", "")
    if not value:
        return None
    value = value.replace(",", ".")
    try:
        n = float(value)
    except ValueError as exc:
        raise ValueError(f"Invalid percentage {value!r} in {file} ({label})") from exc
    if not math.isfinite(n) or not 0 <= n <= 100.0001:
        raise ValueError(f"Percentage outside 0-100 in {file} ({label}): {value!r}")
    return n


def parse_n(value: str, file: Path, label: str) -> int | None:
    """Only used to check whether a cell has ANY trips, not to compare counts."""
    text = str(value or "").strip().replace("'", "").replace("’", "").replace(" ", "")
    if not text:
        return None
    if not text.isdigit():
        raise ValueError(f"Invalid Total_n {value!r} in {file} ({label})")
    return int(text)


def read_csv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    if not path.is_file():
        raise FileNotFoundError(f"Missing CSV: {path}")
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        first = handle.readline()
        delimiter = ";" if first.count(";") > first.count(",") else ","
        handle.seek(0)
        reader = csv.DictReader(handle, delimiter=delimiter)
        headers = [h.strip() if h else "" for h in (reader.fieldnames or [])]
        if not {"Origin", "Mode"}.issubset(headers):
            raise ValueError(f"Expected 'Origin' and 'Mode' headers in {path}; got {headers}")
        if len(headers) != len(set(headers)):
            raise ValueError(f"Duplicate/blank column headers in {path}")
        rows = []
        for row in reader:
            if None in row:
                raise ValueError(f"Invalid CSV row with extra columns in {path}: {row[None]}")
            if any(str(x or "").strip() for x in row.values()):
                rows.append({str(k).strip(): str(v or "").strip() for k, v in row.items()})
    return headers, rows


def destination_columns(headers: list[str], table_type: str, path: Path):
    """Match `REV_%` and reference `REV %` without depending on column order."""
    out = {}
    for header in headers:
        match = re.fullmatch(r"(.+?)[ _](%|n)", header, flags=re.IGNORECASE)
        if match:
            dest = place(match.group(1), table_type)
            typ = match.group(2).lower()
            if (dest, typ) in out:
                raise ValueError(f"Duplicate destination {dest} {typ} in {path}")
            out[(dest, typ)] = header
    base = GROUPS if table_type == "grouped" else MUNICIPALITIES
    for d in base:
        if (d, "%") not in out:
            raise ValueError(f"Missing {d}_% column in {path}")
    return out


def index_reference(path: Path, table_type: str):
    headers, rows = read_csv(path)
    cols = destination_columns(headers, table_type, path)
    shares = {}
    for row in rows:
        origin = place(row["Origin"], table_type)
        mode = mode_name(row["Mode"])
        for (dest, kind), col in cols.items():
            if kind != "%":
                continue
            val = number(row[col], path, f"{origin}/{dest}/{mode}")
            key = (origin, dest, mode)
            if key in shares:
                raise ValueError(f"Duplicate reference row {key} in {path}")
            shares[key] = val
    return shares


def output_number(val: float | None) -> str:
    if val is None:
        return ""
    # One decimal place, with decimal comma for Dutch Excel.
    if abs(val) < 0.049999:
        val = 0.0
    return f"{val:.1f}".replace(".", ",")


def clean_case_name(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "_", name.strip()).strip("._")
    if not cleaned or cleaned in (".", ".."):
        raise ValueError(f"Invalid formulation name: {name!r}")
    return cleaned


def annotate(model_path: Path, table_type: str, reference: dict, output_path: Path,
             case_name: str, include_other: bool, include_municipal_pt: bool):
    headers, records = read_csv(model_path)
    totals_by_origin = {
        (place(row["Origin"], table_type), dest): row
        for row in records if mode_name(row["Mode"]) == "Total"
        for dest, stat in destination_columns(headers, table_type, model_path) if stat == "%"
    }
    model_cols = destination_columns(headers, table_type, model_path)
    original_headers = [h for h in headers if not h.lower().endswith("_%diff")]
    new_headers = []
    annotated = []
    stats = defaultdict(list)
    missing_reference = set()
    no_trips = 0
    base = GROUPS if table_type == "grouped" else MUNICIPALITIES

    for header in original_headers:
        new_headers.append(header)
        match = re.fullmatch(r"(.+?)[ _]%", header, flags=re.IGNORECASE)
        if match:
            new_headers.append(f"{header}Diff")  # REV_% -> REV_%Diff
            annotated.append((header, f"{header}Diff", place(match.group(1), table_type)))

    for row in records:
        origin = place(row["Origin"], table_type)
        mode = mode_name(row["Mode"])
        for pct_header, diff_header, dest in annotated:
            ref_pct = reference.get((origin, dest, mode))
            sim_pct = number(row[pct_header], model_path, f"{origin}/{dest}/{mode}")

            # 0 / 0 is not a modal share. Use TOTAL n only as an availability
            # check, NEVER to compute/weight a difference.
            total_col = model_cols.get((dest, "n"))
            zero_denominator = False
            if total_col is not None:
                total_row = totals_by_origin.get((origin, dest))
                if total_row is not None:
                    total_n = parse_n(total_row[total_col], model_path,
                                          f"{origin}/{dest}/Total")
                    zero_denominator = total_n == 0

            if ref_pct is None or sim_pct is None or zero_denominator:
                row[diff_header] = ""
                if zero_denominator:
                    no_trips += 1
                elif ref_pct is None:
                    missing_reference.add((origin, dest, mode))
                continue
            diff = sim_pct - ref_pct
            row[diff_header] = output_number(diff)
            # Only non-overlapping OD cells are averaged. Both OD-mismatch and
            # PT-mismatch cells remain annotated but are optional in summary.
            if origin in base and dest in base and mode in MODES:
                comparable_geo = (table_type != "grouped" or
                                  (origin != "Other" and dest != "Other") or include_other)
                comparable_pt = (table_type != "municipal" or
                                 mode != "Public transport" or include_municipal_pt)
                if comparable_geo and comparable_pt:
                    stats[mode].append(abs(diff))
        # Excel locale: make source percentage columns numeric when opened as a
        # semicolon CSV in Dutch Excel. Do not change numeric values or n cells.
        for pct_header, _, _ in annotated:
            orig = row.get(pct_header, "")
            if orig and re.fullmatch(r"[+-]?\d+(?:[.,]\d+)?", orig):
                row[pct_header] = orig.replace(".", ",")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, new_headers, delimiter=";", extrasaction="ignore")
        writer.writeheader()
        writer.writerows(records)

    summaries = []
    for mode in (*MODES, "ALL COMPARABLE MODES"):
        selected = (sum((stats[m] for m in MODES), []) if mode == "ALL COMPARABLE MODES"
                    else stats[mode])
        summaries.append({
            "formulation": case_name, "table": table_type, "mode": mode,
            "compared_OD_mode_cells": len(selected),
            "unweighted_mean_absolute_difference_pp":
                output_number(sum(selected) / len(selected)) if selected else "",
        })
    print(f"  {output_path} ({len(records)} rows; {len(annotated)} %Diff columns; "
          f"{no_trips} blank zero-trip cells)")
    if missing_reference:
        print(f"    Note: {len(missing_reference)} origin/destination/mode combinations "
              "lack a matching reference percentage; %Diff left blank.")
    return summaries


def parse_args(argv=None):
    folder = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reference-grouped", type=Path,
                        default=folder / "reference_table_1_REV_Cintura_Other.csv")
    parser.add_argument("--reference-municipal", type=Path,
                        default=folder / "reference_table_2_REV_municipalities.csv")
    parser.add_argument("--case", nargs=3, action="append", metavar=("NAME", "GROUPED_CSV", "MUNICIPAL_CSV"))
    parser.add_argument("--cases-dir", type=Path,
                        help="Optional: subfolders each containing the two default OD-table CSVs")
    parser.add_argument("--output-dir", type=Path, default=Path("modal_split_comparison"))
    parser.add_argument("--include-other-proxy", action="store_true")
    parser.add_argument("--include-municipal-pt-proxy", action="store_true")
    args = parser.parse_args(argv)
    cases = list(args.case or [])
    if args.cases_dir:
        if not args.cases_dir.is_dir():
            parser.error(f"Not a directory: {args.cases_dir}")
        for folder in sorted(f for f in args.cases_dir.iterdir() if f.is_dir()):
            grouped = folder / "mode_choice_rev_cintura_other.csv"
            municipal = folder / "mode_choice_od_table.csv"
            if grouped.is_file() and municipal.is_file():
                cases.append([folder.name, str(grouped), str(municipal)])
    if not cases:
        parser.error("Provide at least one --case NAME GROUPED_CSV MUNICIPAL_CSV")
    case_dirs = [clean_case_name(case[0]) for case in cases]
    if len(set(case_dirs)) != len(case_dirs):
        parser.error("Formulation names must map to distinct output folders")
    return args, cases


def run(argv=None):
    args, cases = parse_args(argv)
    references = {
        "grouped": index_reference(args.reference_grouped, "grouped"),
        "municipal": index_reference(args.reference_municipal, "municipal"),
    }
    all_summaries = []
    for name, grouped_path, municipal_path in cases:
        case_folder = args.output_dir / clean_case_name(name)
        print(f"Formulation: {name}")
        for kind, model_path in (("grouped", Path(grouped_path)),
                                 ("municipal", Path(municipal_path))):
            all_summaries.extend(annotate(
                model_path, kind, references[kind], case_folder / model_path.name,
                name, args.include_other_proxy, args.include_municipal_pt_proxy,
            ))
    args.output_dir.mkdir(parents=True, exist_ok=True)
    with (args.output_dir / "modal_split_summary.csv").open(
        "w", encoding="utf-8-sig", newline=""
    ) as handle:
        writer = csv.DictWriter(handle, delimiter=";", fieldnames=[
            "formulation", "table", "mode", "compared_OD_mode_cells",
            "unweighted_mean_absolute_difference_pp",
        ])
        writer.writeheader()
        writer.writerows(all_summaries)
    notes = [
        "%Diff = simulated modal share (%) minus reference modal share (%), in percentage points.",
        "Simulation and reference n are NOT compared, used as weights, or used to recompute percentages.",
        "The Total_n in a model table is checked only to leave zero-trip OD cells blank.",
        "The optional summary is an unweighted mean of absolute %Diff across distinct OD/mode cells.",
        "Total origin/destination cells are annotated if reference percentages exist, but not summarized.",
        "All geographic and mode-proxy differences remain visible in the annotated CSVs.",
        "By default the summary excludes Other OD pairs (Swiss-only reference vs broader model Other).",
        "By default the summary excludes municipality PT (bus-only reference vs all-PT model).",
        "The 2012-2016 reference covers commuting, so all-trip model cases are not directly comparable.",
        "CSV uses semicolons and decimal commas for Dutch Excel; original input CSVs are not overwritten.",
    ]
    (args.output_dir / "comparison_notes.txt").write_text("\n".join(notes) + "\n", encoding="utf-8")
    print(f"Summary: {args.output_dir / 'modal_split_summary.csv'}")
    return all_summaries


if __name__ == "__main__":
    try:
        run()
    except (FileNotFoundError, ValueError) as exc:
        sys.exit(f"ERROR: {exc}")
