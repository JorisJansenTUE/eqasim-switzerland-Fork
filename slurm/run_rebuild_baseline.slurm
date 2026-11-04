#!/bin/bash
#SBATCH --job-name=locarno_baseline
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=256G
#SBATCH --time=5:00:00
#SBATCH --output=locarno_baseline_%j.out
#SBATCH --error=locarno_baseline_%j.err

set -euo pipefail

# Java 25
module purge
module load EESSI/2026.06
module load Java/25.36

# Latest compiled standalone JAR
JAR="/home/20201733/eqasim-java-Fork/switzerland/target/switzerland.jar"

# Final scenario from successful rebuild
REBUILD_ID="530517"
SCENARIO_DIR="/home/20201733/locarno_ETH_Model/rebuilds/${REBUILD_ID}/01_eth_cut"

CONFIG="$SCENARIO_DIR/eth_rev_config.xml"
OUTPUT="$SCENARIO_DIR/simulation_output"

# CMDP configurator
export eqasim_configurator="org.eqasim.switzerland.ch_cmdp.SwitzerlandConfigurator"

# Verify files
[[ -s "$JAR" ]] || { echo "Missing JAR: $JAR"; exit 1; }
[[ -s "$CONFIG" ]] || { echo "Missing config: $CONFIG"; exit 1; }

cd "$SCENARIO_DIR"

echo "Running on: $(hostname)"
echo "Allocated CPUs: ${SLURM_CPUS_PER_TASK}"
echo "Using JAR: $JAR"
echo "Using config: $CONFIG"
echo "Output directory: $OUTPUT"
echo "Starting simulation: $(date)"

java -Xmx210G \
  -XX:ActiveProcessorCount="${SLURM_CPUS_PER_TASK}" \
  -cp "$JAR" \
  org.eqasim.switzerland.ch_cmdp.RunSimulation \
  --config-path "$CONFIG" \
  --config:controller.outputDirectory "$OUTPUT"

echo "Simulation finished: $(date)"
