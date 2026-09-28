#!/bin/bash
#SBATCH --job-name=locarno_new_cut
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=1:00:00
#SBATCH --output=locarno_new_cut_%j.out
#SBATCH --error=locarno_new_cut_%j.err

set -euo pipefail

module purge
module load Umbrella/2024
module load Java/21.0.7

cd /home/20201733/locarno_ETH_Model

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

JAR="switzerland_run_cutter_test.jar"

# FINAL BASELINE SCENARIO
# Must reference the final network, population, facilities,
# households, vehicles, PT schedule and PT vehicles.
CONFIG="baseline/locarno_run_config.xml"

# New, smaller study-area boundary
CUT_SHAPE="shapes/REV_Cintura_project.shp"

# New output directory
OUTPUT_DIR="REV_cut"

# ------------------------------------------------------------
# Validate inputs
# ------------------------------------------------------------

for FILE in "${JAR}" "${CONFIG}" "${CUT_SHAPE}"; do
    if [[ ! -f "${FILE}" ]]; then
        echo "ERROR: Missing input file: ${FILE}"
        exit 1
    fi
done

# Avoid accidentally overwriting an existing scenario.
if [[ -e "${OUTPUT_DIR}" ]]; then
    echo "ERROR: Output directory already exists:"
    echo "  ${OUTPUT_DIR}"
    echo "Remove or rename it before submitting this job."
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

echo "============================================================"
echo "Cutting FINAL BASELINE to new Locarno extent"
echo "============================================================"

echo "Config:"
echo "  ${CONFIG}"

echo "Shape:"
echo "  ${CUT_SHAPE}"

echo "Output:"
echo "  ${OUTPUT_DIR}"

echo
java -version
echo

# ============================================================
# Cut final baseline scenario
# ============================================================

java -Xmx48G \
  -cp "${JAR}" \
  org.eqasim.core.scenario.cutter.RunScenarioCutter \
  --config-path "${CONFIG}" \
  --output-path "${OUTPUT_DIR}" \
  --extent-path "${CUT_SHAPE}" \
  --prefix locarno_ \
  --threads 8 \
  --eqasim-configurator org.eqasim.switzerland.ch_cmdp.SwitzerlandConfigurator

echo
echo "============================================================"
echo "NEW SCENARIO CUT COMPLETED SUCCESSFULLY"
echo "============================================================"

echo "Output directory:"
echo "  ${OUTPUT_DIR}"

echo
ls -lh "${OUTPUT_DIR}"

echo "============================================================"