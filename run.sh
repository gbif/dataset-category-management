#!/bin/bash

Rscript R/get_candidates.R || exit 1
bash shell/create-issue.sh || exit 1
bash shell/auto-label.sh || exit 1
bash shell/create-category-from-issue.sh 
