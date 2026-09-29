from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# ------------------------------------------------------------------
# Settings
# ------------------------------------------------------------------
SCENARIO = Path("/home/20201733/locarno_ETH_Model/simulation_output_long")
TRIPS_FILE = Path(
     SCENARIO / "output_trips.csv.gz"
)

OUTPUT_FILE = Path(SCENARIO / "travel_times_by_mode.png")
# Internal MATSim mode name: title shown in the graph
MODES_TO_PLOT = {
    "car": "Car",
    "bike": "Bicycle",
    "pt": "Public transport",
    "walk": "Walk",
}

MODE_MAPPING = {
    # Car
    "car": "car",
    "car_loop": "car",
    "car_passenger": "car",
    "car_passenger_loop": "car",
    "truck": "car",

    # Bicycle
    "bike": "bike",
    "bike_loop": "bike",

    # Public transport
    "pt": "pt",

    # Walk
    "walk": "walk",
    "walk_loop": "walk",
    "remote_walk": "walk",
}

BIN_WIDTH_MINUTES = 1
REFERENCE_TIME_MINUTES = 20

# Optional fixed x-axis limits. Use None for automatic limits.
X_LIMITS = {
    "car": (0, 45),
    "bike": (0, 45),
    "pt": (0, 60),
    "walk": (0, 45),
}
#X_LIMITS = None

# ------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------

def matsim_time_to_seconds(values: pd.Series) -> pd.Series:
    """
    Convert MATSim travel times to seconds.

    Supports both:
        452.0
        00:07:32
    """

    numeric_seconds = pd.to_numeric(values, errors="coerce")

    duration_seconds = pd.to_timedelta(
        values.astype(str),
        errors="coerce",
    ).dt.total_seconds()

    return numeric_seconds.fillna(duration_seconds)


def plot_travel_time_histograms(trips: pd.DataFrame) -> None:

    number_of_modes = len(MODES_TO_PLOT)

    fig, axes = plt.subplots(
        1,
        number_of_modes,
        figsize=(5.5 * number_of_modes, 4.5),
        squeeze=False,
    )

    axes = axes.flatten()

    for ax, (mode, title) in zip(axes, MODES_TO_PLOT.items()):

        mode_trips = trips.loc[
            trips["main_mode"] == mode,
            "travel_time_minutes",
        ].dropna()

        if mode_trips.empty:
            ax.set_title(f"{title}\n(no trips found)")
            ax.set_axis_off()
            continue

        if X_LIMITS is not None:
            x_limits = X_LIMITS.get(mode)
        else:
            x_limits = None

        if x_limits is None:
            maximum_time = np.ceil(mode_trips.max())
            minimum_time = 0
        else:
            minimum_time, maximum_time = x_limits

        bins = np.arange(
            minimum_time,
            maximum_time + BIN_WIDTH_MINUTES,
            BIN_WIDTH_MINUTES,
        )

        counts, edges = np.histogram(mode_trips, bins=bins)

        # Grey before the reference time, green afterwards
        bar_colours = [
            "#bdbdbd" if left_edge < REFERENCE_TIME_MINUTES else "#2a9d8f"
            for left_edge in edges[:-1]
        ]

        ax.bar(
            edges[:-1],
            counts,
            width=np.diff(edges),
            align="edge",
            color=bar_colours,
            edgecolor="white",
            linewidth=0.5,
        )

        ax.axvline(
            REFERENCE_TIME_MINUTES,
            color="#f2b705",
            linestyle="--",
            linewidth=2,
        )

        ax.set_title(title, loc="left")
        ax.set_xlabel(
            f"Travel time (min, {BIN_WIDTH_MINUTES}-min brackets)"
        )
        ax.set_ylabel("# trips")

        ax.set_xlim(minimum_time, maximum_time)
        ax.grid(axis="y", alpha=0.3)
        ax.set_axisbelow(True)

        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)

        print(
            f"{title}: {len(mode_trips):,} trips, "
            f"mean = {mode_trips.mean():.1f} min, "
            f"median = {mode_trips.median():.1f} min"
        )

    fig.tight_layout()
    fig.savefig(OUTPUT_FILE, dpi=300, bbox_inches="tight")
    plt.show()

    print(f"\nFigure written to: {OUTPUT_FILE.resolve()}")


# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

def main() -> None:

    if not TRIPS_FILE.exists():
        raise FileNotFoundError(
            f"Trips file not found:\n{TRIPS_FILE.resolve()}"
        )

    trips = pd.read_csv(
        TRIPS_FILE,
        sep=";",
        compression="infer",
        low_memory=False,
    )

    required_columns = {"main_mode", "trav_time"}
    missing_columns = required_columns - set(trips.columns)

    if missing_columns:
        raise ValueError(
            f"Missing columns: {sorted(missing_columns)}\n"
            f"Available columns: {list(trips.columns)}"
        )

    trips["main_mode_raw"] = (
        trips["main_mode"]
        .astype(str)
        .str.strip()
        .str.lower()
    )

    print("Original MATSim modes:")
    print(trips["main_mode_raw"].value_counts())
    print()

    # Aggregate detailed MATSim modes into four main modes
    trips["main_mode"] = trips["main_mode_raw"].map(MODE_MAPPING)

    # Show modes which are not used in the analysis
    unmapped_modes = trips.loc[
        trips["main_mode"].isna(),
        "main_mode_raw",
    ].value_counts()

    if not unmapped_modes.empty:
        print("Excluded/unmapped modes:")
        print(unmapped_modes)
        print()

    # Keep only Car / Bike / PT / Walk
    trips = trips.loc[
        trips["main_mode"].notna()
    ].copy()

    print("Aggregated modes:")
    print(trips["main_mode"].value_counts())
    print()

    trips["travel_time_seconds"] = matsim_time_to_seconds(
        trips["trav_time"]
    )

    trips["travel_time_minutes"] = (
        trips["travel_time_seconds"] / 60
    )

    # Remove invalid or zero-duration trips
    trips = trips.loc[
        np.isfinite(trips["travel_time_minutes"])
        & (trips["travel_time_minutes"] > 0)
    ].copy()

    plot_travel_time_histograms(trips)


if __name__ == "__main__":
    main()