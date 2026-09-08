#!/bin/bash
#SBATCH --job-name=eqasim_network
#SBATCH --partition=mech-cst-mov.cpu.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --mem=200G
#SBATCH --time=05:00:00
#SBATCH --output=network_%j.out
#SBATCH --error=network_%j.err
#SBATCH --no-requeue

set -euo pipefail

# ------------------------------------------------------------
# TU/e software environment
# ------------------------------------------------------------

module purge
module load Umbrella/2024
module load Python/3.10.13-GCCcore-11.3.0
module load Java/21.0.7

# ------------------------------------------------------------
# Maven
# ------------------------------------------------------------

export MAVEN_HOME=$HOME/software/apache-maven-3.9.6
export PATH=$MAVEN_HOME/bin:$PATH

# ------------------------------------------------------------
# Project
# ------------------------------------------------------------

cd $HOME/eqasim-switzerland-Fork

source .venv/bin/activate

# Make Python output appear immediately in the Slurm log
export PYTHONUNBUFFERED=1

# ------------------------------------------------------------
# Diagnostics
# ------------------------------------------------------------

echo "========================================"
echo "eqasim Switzerland network generation"
echo "========================================"
echo "Host:       $(hostname)"
echo "Date:       $(date)"
echo "Directory:  $(pwd)"
echo "CPUs:       $SLURM_CPUS_PER_TASK"
echo

echo "Python:"
python --version
which python

echo
echo "Java:"
java -version
which java

echo
echo "Maven:"
mvn -version
which mvn

echo
echo "========================================"
echo "Starting synpp"
echo "========================================"

python -m synpp config_network_test.yml

echo
echo "========================================"
echo "Finished"
echo "Date: $(date)"
echo "========================================"