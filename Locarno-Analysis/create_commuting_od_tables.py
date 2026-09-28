"""Create REV-municipality and REV/Cintura/Other commuting OD-mode tables.

Run from the project root:
    python -m results.create_commuting_od_tables

If the script is saved somewhere other than results/, adjust the command.
The script uses the existing project DATA_DIR and MATSim output_trips.csv.gz.
"""

from pathlib import Path
import unicodedata

import geopandas as gpd
import numpy as np
import pandas as pd


# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------
SCENARIO = Path("/home/20201733/locarno_ETH_Model/simulation_output_long")
TRIPS_FILE = SCENARIO / "output_trips.csv.gz"
BOUNDARIES_FILE = Path("/home/20201733/locarno_ETH_Model/shapes/swissBOUNDARIES3D.gpkg")
BOUNDARIES_LAYER = "tlm_hoheitsgebiet"
MUNICIPALITY_NAME_COLUMN = "name"

REV_TABLE_CSV = SCENARIO / "mode_choice_od_table_Home.csv"  # original filename
GROUP_TABLE_CSV = SCENARIO / "mode_choice_rev_cintura_other_Home.csv"

REV_MUNICIPALITIES = ["Ascona", "Locarno", "Minusio", "Muralto"]
CINTURA_MUNICIPALITIES = [
    "Terre di Pedemonte",
    "Orselina",
    "Ronco sopra Ascona",
    "Losone",  
    "Brione sopra Minusio",
    "Tenero-Contra",
]

REV = "REV"
CINTURA = "Cintura REV"
OTHER = "Other"
GROUP_ORDER = [REV, CINTURA, OTHER]

# Retain the same mode definitions as in the existing municipality table.
MODE_MAPPING = {
    "car": "Car",
    "car_loop": "Car",
    "car_passenger": "Car",
    "car_passenger_loop": "Car",
    "bike": "Bicycle",
    "bike_loop": "Bicycle",
    "pt": "Public transport",
    "walk": "Walk",
    "walk_loop": "Walk",
    "remote_walk": "Walk",
}
MODE_ORDER = ["Walk", "Bicycle", "Car", "Public transport"]
COORD_COLUMNS = ["start_x", "start_y", "end_x", "end_y"]
TRIP_COLUMNS = [
    "start_activity_type", "end_activity_type", "main_mode", *COORD_COLUMNS
]


def normalized_name(value: str) -> str:
    """Match municipality names regardless of capitalization/extra spaces."""
    return " ".join(unicodedata.normalize("NFKC", str(value)).casefold().split())


def load_municipalities() -> gpd.GeoDataFrame:
    """Load only the named REV and Cintura polygons (in MATSim EPSG:2056)."""
    # REV has priority if a municipality is accidentally listed in both groups.
    all_names = REV_MUNICIPALITIES + CINTURA_MUNICIPALITIES
    wanted = {normalized_name(name) for name in all_names}

    municipalities = gpd.read_file(BOUNDARIES_FILE, layer=BOUNDARIES_LAYER)
    if municipalities.crs is None:
        raise ValueError(f"Missing CRS in {BOUNDARIES_FILE}")
    if MUNICIPALITY_NAME_COLUMN not in municipalities.columns:
        raise ValueError(f"Missing municipality column: {MUNICIPALITY_NAME_COLUMN}")

    municipalities["name_key"] = municipalities[MUNICIPALITY_NAME_COLUMN].map(
        normalized_name
    )
    municipalities = municipalities.loc[
        municipalities["name_key"].isin(wanted), ["name_key", "geometry"]
    ].copy()
    found = set(municipalities["name_key"])
    if wanted - found:
        raise ValueError(
            "Missing municipalities in the boundary file: "
            + ", ".join(sorted(wanted - found))
        )

    # A municipality can have multiple polygon pieces; combine them first so
    # one coordinate does not receive duplicate matches for the same name.
    municipalities = municipalities.dissolve(by="name_key", as_index=False)
    municipalities = municipalities.to_crs("EPSG:2056")
    return municipalities


def assign_municipality(
    trips: pd.DataFrame,
    municipalities: gpd.GeoDataFrame,
    x_column: str,
    y_column: str,
) -> pd.Series:
    """Return a canonical named municipality, or 'Other' for every other point.

    All records reaching this function have valid coordinates. In particular,
    points in Gordola, Lavertezzo, and outside the project shape become Other.
    """
    points = gpd.GeoDataFrame(
        index=trips.index,
        geometry=gpd.points_from_xy(trips[x_column], trips[y_column]),
        crs="EPSG:2056",
    )
    matched = gpd.sjoin(
        points,
        municipalities[["name_key", "geometry"]],
        how="left",
        predicate="within",
    )
    if not matched.index.is_unique:
        raise ValueError(
            "A coordinate matched multiple municipality polygons. "
            "Check for overlapping geometries in the boundary file."
        )

    canonical = {normalized_name(name): name for name in REV_MUNICIPALITIES}
    canonical.update({
        normalized_name(name): name
        for name in CINTURA_MUNICIPALITIES
        if normalized_name(name) not in canonical
    })
    result = matched["name_key"].map(canonical).fillna(OTHER)
    return result.reindex(trips.index)


def make_od_mode_table(
    trips: pd.DataFrame,
    origin_column: str,
    destination_column: str,
    origins: list[str],
    destinations: list[str],
    *,
    overall_origin: bool,
    total_destination: bool,
) -> pd.DataFrame:
    """OD cells contain counts and mode percentages *within that OD cell*.

    A Total destination, when requested, uses all included destinations for
    that origin as its denominator. A Total origin, when requested, aggregates
    all included origins for that destination. This matches the original REV
    municipality table's denominator convention.
    """
    relevant = trips.loc[
        trips[origin_column].isin(origins)
        & trips[destination_column].isin(destinations)
    ]
    od_index = pd.MultiIndex.from_product(
        [origins, destinations], names=[origin_column, destination_column]
    )
    counts = pd.DataFrame(0, index=od_index, columns=MODE_ORDER, dtype="int64")
    if not relevant.empty:
        observed_counts = relevant.groupby(
            [origin_column, destination_column, "mode"], observed=True
        ).size().unstack("mode", fill_value=0)
        counts = observed_counts.reindex(
            index=od_index, columns=MODE_ORDER, fill_value=0
        ).astype("int64")

    destination_labels = destinations + (["Total"] if total_destination else [])
    origin_labels = origins + (["Total"] if overall_origin else [])
    columns = pd.MultiIndex.from_product(
        [destination_labels, ["n", "%"]], names=["Destination", ""]
    )

    rows = []
    row_index = []
    for origin in origin_labels:
        # Index is destination, columns are modes.
        if origin == "Total":
            origin_counts = counts.groupby(level=1).sum()
        else:
            origin_counts = counts.xs(origin, level=0)

        cell_counts = {dest: origin_counts.loc[dest] for dest in destinations}
        if total_destination:
            cell_counts["Total"] = origin_counts.sum(axis=0)

        for mode in MODE_ORDER + ["Total"]:
            row = {}
            for destination in destination_labels:
                cell = cell_counts[destination]
                denominator = int(cell.sum())
                n = denominator if mode == "Total" else int(cell[mode])
                row[(destination, "n")] = n
                row[(destination, "%")] = (
                    100.0 * n / denominator if denominator else 0.0
                )
            rows.append(row)
            row_index.append((origin, mode))

    table = pd.DataFrame(
        rows,
        index=pd.MultiIndex.from_tuples(row_index, names=["Origin", "Mode"]),
    )
    table = table.reindex(columns=columns)
    percent_columns = [column for column in table if column[1] == "%"]
    table[percent_columns] = table[percent_columns].round(1)
    return table


def write_csv(table: pd.DataFrame, path: Path) -> None:
    """Flatten column headers for the existing semicolon-delimited format."""
    flat = table.copy()
    flat.columns = [f"{destination}_{stat}" for destination, stat in flat.columns]
    path.parent.mkdir(parents=True, exist_ok=True)
    flat.to_csv(path, sep=";", encoding="utf-8-sig")
    print(f"Written: {path.resolve()}")


def main() -> None:
    for path in [TRIPS_FILE, BOUNDARIES_FILE]:
        if not path.is_file():
            raise FileNotFoundError(f"Missing input file: {path.resolve()}")

    print("Reading MATSim trips...")
    trips = pd.read_csv(
        TRIPS_FILE, sep=";", compression="infer", low_memory=False,
        usecols=TRIP_COLUMNS,
    )
    trips = trips.loc[
        trips["start_activity_type"].eq("home")
        | trips["end_activity_type"].eq("home")
    ].copy()
    print(f"Direct home-to-work trips: {len(trips):,}")

    trips["main_mode_raw"] = trips["main_mode"].astype("string").str.strip().str.lower()
    trips["mode"] = trips["main_mode_raw"].map(MODE_MAPPING)
    excluded_modes = trips.loc[trips["mode"].isna(), "main_mode_raw"].value_counts(
        dropna=False
    )
    if not excluded_modes.empty:
        print("Excluded, unmapped modes (same mapping as the original script):")
        print(excluded_modes.to_string())
    trips = trips.loc[trips["mode"].notna()].copy()

    for column in COORD_COLUMNS:
        trips[column] = pd.to_numeric(trips[column], errors="coerce")
    valid_coordinates = np.isfinite(trips[COORD_COLUMNS].to_numpy()).all(axis=1)
    if (~valid_coordinates).sum():
        print(f"Dropping {(~valid_coordinates).sum():,} trips with missing/invalid coordinates")
    trips = trips.loc[valid_coordinates].copy()

    municipalities = load_municipalities()
    print("Assigning origin municipalities...")
    trips["origin_municipality"] = assign_municipality(
        trips, municipalities, "start_x", "start_y"
    )
    print("Assigning destination municipalities...")
    trips["destination_municipality"] = assign_municipality(
        trips, municipalities, "end_x", "end_y"
    )

    rev_names = {normalized_name(name) for name in REV_MUNICIPALITIES}
    cintura_names = {normalized_name(name) for name in CINTURA_MUNICIPALITIES} - rev_names
    if {normalized_name(name) for name in CINTURA_MUNICIPALITIES} & rev_names:
        print("NOTE: Minusio appears in both supplied groups; assigning it to REV only.")

    def group_for(name: str) -> str:
        key = normalized_name(name)
        if key in rev_names:
            return REV
        if key in cintura_names:
            return CINTURA
        return OTHER

    trips["origin_group"] = trips["origin_municipality"].map(group_for)
    trips["destination_group"] = trips["destination_municipality"].map(group_for)

    # Table 2: retain original four-municipality OD selection and output name.
    rev_table = make_od_mode_table(
        trips,
        "origin_municipality", "destination_municipality",
        REV_MUNICIPALITIES, REV_MUNICIPALITIES,
        overall_origin=True, total_destination=True,
    )

    # Table 1: three origin groups x three destination groups. Other also
    # includes trips outside the project area; no study-shape filter is applied.
    grouped_table = make_od_mode_table(
        trips,
        "origin_group", "destination_group",
        GROUP_ORDER, GROUP_ORDER,
        overall_origin=False, total_destination=False,
    )

    print("\nREV municipality OD table:\n", rev_table)
    print("\nREV / Cintura REV / Other OD table:\n", grouped_table)
    write_csv(rev_table, REV_TABLE_CSV)
    write_csv(grouped_table, GROUP_TABLE_CSV)
    print(
        "NOTE: Other includes Gordola, Lavertezzo, and every location outside "
        "the named REV/Cintura municipalities (also beyond the study boundary)."
    )


if __name__ == "__main__":
    main()
