#!/bin/bash

# Check for required commands
for cmd in shyaml awk gh; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found." >&2
        exit 1
    fi
done

# Read categories from config.yaml and process each one
cat config.yaml | shyaml get-values categories | while read datasetCategory; do
    echo "Checking log for category: $datasetCategory"
    
    # check that the log file agrees with the issues on github
    log_keys=$(awk -F'\t' -v cat="$datasetCategory" '$2 == cat {print $1}' shell/issue_log.txt)

    gh_keys=$(gh issue list --state all --label "$datasetCategory" --limit 1000 \
      | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')

    # Compare and list UUIDs in gh_keys not in log_keys
    echo "UUIDs in GitHub issues but not in log file for $datasetCategory:"
    comm -23 <(echo "$gh_keys" | sort) <(echo "$log_keys" | sort)
    echo "---"
done




