#!/bin/bash
#SBATCH --job-name=bike_preprocess
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --time=01:00:00
#SBATCH --output=bike_preprocess_%j.out
#SBATCH --error=bike_preprocess_%j.err
#SBATCH --no-requeue

set -euo pipefail

module purge
module load Umbrella/2024
module load Python/3.10.13-GCCcore-11.3.0

cd $HOME/eqasim-switzerland-Fork
source .venv/bin/activate

export PYTHONUNBUFFERED=1

INPUT_OSM="$HOME/eqasim-switzerland-Fork/data/osm/Switzerland-260413.osm.pbf"
OUTPUT_OSM="$HOME/eqasim-switzerland-Fork/data/osm/Switzerland-260413-bike.osm.pbf"

echo "========================================"
echo "Bike-suitable OSM preprocessing"
echo "========================================"
echo "Host:   $(hostname)"
echo "Date:   $(date)"
echo "Input:  $INPUT_OSM"
echo "Output: $OUTPUT_OSM"
echo

python -m data.osm.bike_preprocessing \
    "$INPUT_OSM" \
    "$OUTPUT_OSM"

echo
echo "Finished: $(date)"
echo

ls -lh "$OUTPUT_OSM"