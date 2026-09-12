#!/bin/bash
#SBATCH --job-name=check_bike_routes
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --time=0:30:00
#SBATCH --output=check_bike_routes_%j.out
#SBATCH --error=check_bike_routes_%j.err

set -euo pipefail

module purge
module load Umbrella/2024
module load Python/3.10.13-GCCcore-11.3.0

cd /home/20201733/locarno_ETH_Model

source /home/20201733/eqasim-switzerland-Fork/.venv/bin/activate

python inspect_failed_bike_routes.py