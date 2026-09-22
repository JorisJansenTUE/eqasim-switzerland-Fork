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

module purge
module load Umbrella/2024
module load Java/21.0.7

cd /home/20201733/locarno_ETH_Model

java -Xmx210G \
  -cp switzerland_run.jar \
  org.eqasim.switzerland.ch_cmdp.RunSimulation \
  --config-path baseline/locarno_run_config.xml