#!/bin/bash

# Initialize issue counter
issue_counter=0

# Function to check GitHub API rate limit
check_rate_limit() {
    echo "Checking GitHub API rate limit..."
    rate_limit_response=$(gh api rate_limit)
    
    # Extract GraphQL remaining requests
    graphql_remaining=$(echo "$rate_limit_response" | jq -r '.resources.graphql.remaining')
    
    echo "GraphQL remaining: $graphql_remaining"
    
    # If remaining requests are less than 50, pause for 1 hour 10 minutes
    if [ "$graphql_remaining" -lt 300 ]; then
        echo "GraphQL rate limit low ($graphql_remaining remaining). Pausing for 1 hour 10 minutes..."
        sleep 4200  # Sleep for 1 hour 10 minutes (4200 seconds)
        echo "Resuming after rate limit pause..."
    fi
}

# Initial rate limit check
echo "Starting auto-label script - checking initial rate limit..."
check_rate_limit

# searches for autoLabel labels and auto labels with add-category

cat config.yaml | shyaml get-values categories | while read cat; do 
    cat="${cat//-/}"
    echo category:"$cat"
    
    cat category-configs/$cat.yaml | shyaml get-values autoLabel | while read label; do
        label="${label//- /}"
        echo " label: $label"
        issues=$(gh issue list --state open --label "$label" --label "$cat" --limit 1000 | awk '{print $1}')
        echo "  issues found: $issues"
        for issue in $issues; do
            echo "  labeling issue $issue with add-category"
            if gh issue edit "$issue" --add-label "add-category"; then
                echo "    successfully labeled issue $issue"
            else
                echo "    failed to label issue $issue - continuing"
            fi
            
            # Increment counter and check rate limit every 5 issues
            ((issue_counter++))
            if [ $((issue_counter % 5)) -eq 0 ]; then
                check_rate_limit
            fi
        done
        
    done

done

echo "Auto-label script completed. Total issues labeled: $issue_counter"




