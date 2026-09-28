#!/bin/bash
#SBATCH --job-name=eqasim_java_build
#SBATCH --partition=tue.cpu2.q
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --output=eqasim_build_%j.out
#SBATCH --error=eqasim_build_%j.err

set -euo pipefail

# ------------------------------------------------------------
# TU/e software environment
# ------------------------------------------------------------

module purge
module load Umbrella/2024
module load Java/21.0.7

# ------------------------------------------------------------
# Maven
# ------------------------------------------------------------

export MAVEN_HOME="$HOME/software/apache-maven-3.9.6"
export PATH="$MAVEN_HOME/bin:$PATH"

# ------------------------------------------------------------
# Project
# ------------------------------------------------------------

cd "$HOME/eqasim-java-Fork"

# ------------------------------------------------------------
# Diagnostics
# ------------------------------------------------------------

echo "============================================================"
echo "Building modified eqasim-java"
echo "============================================================"

echo "Host:       $(hostname)"
echo "Date:       $(date)"
echo "Directory:  $(pwd)"
echo "CPUs:       $SLURM_CPUS_PER_TASK"

echo
echo "Git branch:"
git branch --show-current

echo
echo "Git commit:"
git log -1 --oneline

echo
echo "Java:"
java -version

echo
echo "Maven:"
mvn -version

echo
echo "============================================================"
echo "Starting Maven build"
echo "============================================================"

# Build Switzerland and its required modules, including the
# modified core module containing NetworkCutter.java.

mvn -pl switzerland -am clean package \
    -Pstandalone \
    -DskipTests \
    -T 8

echo
echo "============================================================"
echo "Build completed successfully"
echo "============================================================"

echo "Date: $(date)"

echo
echo "Generated JAR files:"

find switzerland/target \
    -maxdepth 1 \
    -name "*.jar" \
    -printf "%f  %s bytes\n"

echo
echo "============================================================"