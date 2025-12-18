#!/bin/bash

set -uo pipefail

# Initialize issue counte
issue_counter=0

# Function to check GitHub API rate limit
check_rate_limit() {
    echo "Checking GitHub API rate limit..."
    rate_limit_response=$(gh api rate_limit)
    
    # Extract GraphQL remaining requests
    graphql_remaining=$(echo "$rate_limit_response" | jq -r '.resources.graphql.remaining')
    
    echo "GraphQL remaining: $graphql_remaining"
    
    # If remaining requests are less than 100, pause for 1 hour 10 minutes
    if [ "$graphql_remaining" -lt 500 ]; then
        echo "GraphQL rate limit low ($graphql_remaining remaining). Pausing for 1 hour 10 minutes..."
        sleep 4200  # Sleep for 1 hour 10 minutes (4200 seconds)
        echo "Resuming after rate limit pause..."
    fi
}

# Check for required commands
for cmd in gh jq grep sort uniq awk shyaml; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found." >&2
        exit 1
    fi
done

# Initial rate limit check
echo "Starting create-category-from-issue script - checking initial rate limit..."
check_rate_limit

# Read categories from config.yaml and process each one
cat config.yaml | shyaml get-values categories | while read category; do
    echo "Processing category: $category"
    
    # Extract all labels from open issues with label "add-category" for this category
    datasetKeys=$(gh issue list --label "add-category" --label "$category" --state open  --limit 1000 --json labels | jq -r '.[].labels[].name' | grep -v 'pub:' | grep -E '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' | sort | uniq)
    echo "UUID labels (excluding 'pub:') for $category:" 
    echo "$datasetKeys"

    if [ -z "$datasetKeys" ]; then
        echo "No datasetKeys found for category $category. Continuing to next category."
        continue
    fi

    for datasetKey in $datasetKeys; do
        echo "Processing datasetKey: $datasetKey for category: $category"
        issue_number=$(gh issue list --label "$datasetKey" --label "add-category" --label "$category" --state open | awk '{print $1}')
        echo "Issue number: $issue_number"
        if [ -z "$issue_number" ]; then
            echo "No open issue found for datasetKey $datasetKey and category $category. Continuing to next dataset."
            continue
        fi
        # run update-category.sh
        if bash shell/update-category.sh "$datasetKey" "$category" "$issue_number"; then
            echo "update-category.sh succeeded for $datasetKey with category $category"
        else
            echo "update-category.sh failed for $datasetKey with category $category - continuing to next dataset"
            continue
        fi
        
        # close this issue and add label "category-added"
        echo "Closing issue #$issue_number and adding label 'category-added'"
        gh issue edit "$issue_number" --add-label "category-added" 
        gh issue close "$issue_number" 
        
        # Increment counter and check rate limit every 5 issues
        ((issue_counter++))
        if [ $((issue_counter % 5)) -eq 0 ]; then
            check_rate_limit
        fi
    done
done

echo "Create-category-from-issue script completed. Total issues processed: $issue_counter"

