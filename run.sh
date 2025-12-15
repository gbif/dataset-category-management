#!/bin/bash
set -e  # Exit immediately if any command fails

# Rscript R/get_candidates.R
bash shell/create-issue.sh
# bash shell/auto-label.sh
# bash shell/create-category-from-issue.sh
