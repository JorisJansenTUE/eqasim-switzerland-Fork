#!/bin/bash
#SBATCH --job-name=old_locarno_cut
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=192G
#SBATCH --time=5:00:00
#SBATCH --output=old_locarno_cut_%j.out
#SBATCH --error=old_locarno_cut_%j.err

set -euo pipefail

module purge
module load Umbrella/2024
module load Java/21.0.7

cd /home/20201733/locarno_ETH_Model

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

JAR="switzerland_run.jar"

# ORIGINAL ETH config:
# old network
# old population
# old facilities
# old households
# old vehicles
# old PT schedule / PT vehicles
CONFIG="locarno_config.xml"

CUT_SHAPE="shapes/Locarno_Agglomeration_200m.shp"

OUTPUT_DIR="old_locarno_cut"

# ------------------------------------------------------------
# Clean output
# ------------------------------------------------------------

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

echo "============================================================"
echo "Cutting ORIGINAL ETH scenario to final Locarno extent"
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
# Cut original ETH scenario
# ============================================================

java -Xmx160G \
  -cp "${JAR}" \
  org.eqasim.core.scenario.cutter.RunScenarioCutter \
  --config-path "${CONFIG}" \
  --output-path "${OUTPUT_DIR}" \
  --extent-path "${CUT_SHAPE}" \
  --prefix locarno_ \
  --threads 24 \
  --eqasim-configurator org.eqasim.switzerland.ch_cmdp.SwitzerlandConfigurator

echo
echo "============================================================"
echo "FIRST CUT COMPLETED SUCCESSFULLY"
echo "============================================================"
echo "Output directory:"
echo "  ${OUTPUT_DIR}"
echo
ls -lh "${OUTPUT_DIR}"
echo "============================================================"