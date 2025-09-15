#!/bin/bash

datasetCategory="eDNA"
# check that the log file agrees with the issues on github
log_keys=$(awk -F'\t' -v cat="$datasetCategory" '$2 == cat {print $1}' shell/issue_log.txt)

gh_keys=$(gh issue list --state all --label "$datasetCategory" --limit 1000 \
  | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')

# Compare and list UUIDs in gh_keys not in log_keys
comm -23 <(echo "$gh_keys" | sort) <(echo "$log_keys" | sort)




