#!/bin/bash

# Extract all labels from open issues with label "machine-tag"
datasetKeys=$(gh issue list --label "machine-tag" --label "eDNA" --state open  --limit 1000 --json labels | jq -r '.[].labels[].name' | grep -v 'pub:' | grep -E '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' | sort | uniq)
echo "UUID labels (excluding 'pub:'):" 
echo "$datasetKeys"

for datasetKey in $datasetKeys; do
    echo "Processing datasetKey: $datasetKey"
    Rscript --quiet R/create_mt.R "$datasetKey" || exit 1

    # close this issue and add label "machine-tag-created"
    issue_number=$(gh issue list --label "$datasetKey" --label "machine-tag" --label "eDNA" --state open | awk '{print $1}')
    if [ -n "$issue_number" ]; then
        echo "Closing issue #$issue_number and adding label 'machine-tag-created'"
        gh issue edit "$issue_number" --add-label "machine-tag-created" || exit 1
        gh issue close "$issue_number" || exit 1
    else
        echo "No open issue found for datasetKey $datasetKey"
    fi

done



