#!/bin/bash

set -euo pipefail

# Check for required commands
for cmd in gh jq grep sort uniq awk; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found." >&2
        exit 1
    fi
done

# Extract all labels from open issues with label "machine-tag"
datasetKeys=$(gh issue list --label "add-category" --label "eDNA" --state open  --limit 1000 --json labels | jq -r '.[].labels[].name' | grep -v 'pub:' | grep -E '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' | sort | uniq)
echo "UUID labels (excluding 'pub:'):" 
echo "$datasetKeys"

if [ -z "$datasetKeys" ]; then
    echo "No datasetKeys found. Exiting."
    exit 0
fi

for datasetKey in $datasetKeys; do
    echo "Processing datasetKey: $datasetKey"
    issue_number=$(gh issue list --label "$datasetKey" --label "add-category" --label "eDNA" --state open | awk '{print $1}')
    echo "Issue number: $issue_number"
    if [ -z "$issue_number" ]; then
        echo "No open issue found for datasetKey $datasetKey. Stopping script."
        exit 1
    fi
    # run update-category.sh
    if bash shell/update-category.sh "$datasetKey" "eDNA" "$issue_number"; then
        echo "update-category.sh succeeded for $datasetKey"
    else
        echo "update-category.sh failed for $datasetKey" 
        exit 1
    fi
    
    # close this issue and add label "category-added"
    echo "Closing issue #$issue_number and adding label 'category-added'"
    gh issue edit "$issue_number" --add-label "category-added" 
    gh issue close "$issue_number" 
done

