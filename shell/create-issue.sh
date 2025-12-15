#!/bin/bash

# Initialize issue counter
issue_counter=0

# Parse command line arguments
CATEGORY_ARG="$1"

# Determine which files to process
if [ -n "$CATEGORY_ARG" ]; then
    # Check if the category file exists
    if [ -f "candidate-tsv/${CATEGORY_ARG}.tsv" ]; then
        FILES="candidate-tsv/${CATEGORY_ARG}.tsv"
        echo "Processing single category: $CATEGORY_ARG"
    else
        echo "Error: Category file 'candidate-tsv/${CATEGORY_ARG}.tsv' not found."
        echo "Available categories:"
        ls candidate-tsv/*.tsv | sed 's|candidate-tsv/||' | sed 's|.tsv||'
        exit 1
    fi
else
    # Process all TSV files
    FILES="candidate-tsv/*"
    echo "Processing all categories"
fi

# Function to check GitHub API rate limit
check_rate_limit() {
    echo "Checking GitHub API rate limit..."
    rate_limit_response=$(gh api rate_limit)
    
    # Extract GraphQL remaining requests
    graphql_remaining=$(echo "$rate_limit_response" | jq -r '.resources.graphql.remaining')
    
    echo "GraphQL remaining: $graphql_remaining"
    
    # If remaining requests are less than 100, pause for 1 hour 10 minutes
    if [ "$graphql_remaining" -lt 400 ]; then
        echo "GraphQL rate limit low ($graphql_remaining remaining). Pausing for 1 hour 10 minutes..."
        sleep 4200  # Sleep for 1 hour 10 minutes (4200 seconds)
        echo "Resuming after rate limit pause..."
    fi
}

# Initial rate limit check
echo "Starting script - checking initial rate limit..."
check_rate_limit

for file in $FILES; do
    # Do something with "$file"
    echo "Processing $file"
    echo "---------------------"
    while IFS=$'\t' read -r datasetKey publisherKey searchQuery title publisher datasetCategory; do
        # process columns here
        label=""
        [ "$datasetKey" != "NA" ] && label+="$datasetKey,"
        [ "$datasetCategory" != "NA" ] && label+="$datasetCategory,"
        [ "$publisherKey" != "NA" ] && label+="pub:$publisherKey,"
        [ "$searchQuery" != "NA" ] && label+="$searchQuery,"
        # check if issue is log file 
        # Check if this exact datasetKey + datasetCategory combination exists in the log
        if grep -Fq "${datasetKey}	${datasetCategory}" shell/issue_log.txt; then
            echo "DatasetKey $datasetKey already exists for category $datasetCategory. Skipping."
            continue
        fi        
        # creating issue 
        label="${label%,}"  # Remove trailing comma
        label="${label//[[:space:]]/}"
        
        # Fetch dataset description from GBIF API
        dataset_json=$(curl -s "https://api.gbif.org/v1/dataset/$datasetKey")
        description=$(echo "$dataset_json" | jq -r '.description // ""')
        
        # Strip HTML tags from description
        description=$(echo "$description" | sed 's/<[^>]*>//g')
        
        # Limit description to 2000 characters
        if [ ${#description} -gt 2000 ]; then
            description="${description:0:2000}..."
        fi
        
        # Build issue body
        body="[Dataset](https://www.gbif.org/dataset/$datasetKey)"$'\n'"[MachineTag](https://registry.gbif.org/dataset/$datasetKey/machineTag)"
        
        # Add description if it exists
        if [ -n "$description" ] && [ "$description" != "null" ]; then
            body="$body"$'\n\n'"## Description"$'\n'"$description"
        fi
        
        echo "$title"
        echo "$body"
        echo "$label"
        # Create missing labels
        IFS=',' read -ra labels <<< "$label"
        for l in "${labels[@]}"; do
            if ! gh label list | grep -q "^$l"; then
                gh label create "$l" --color "#ededed" --description "Auto-generated label"
            fi
        done
        # Check if already exists
        if ! gh issue list --state all --search "$title" --label "$datasetKey" --label "$datasetCategory" | grep "$title" | grep "$datasetKey" | grep -q "$datasetCategory"; then
            echo "creating new issue"
            # Create the issue
            gh issue create --title "$title" --body "$body" --label "$label" || exit 1
            echo -e "$datasetKey\t$datasetCategory" >> "shell/issue_log.txt"
            
            # Increment counter and check rate limit every 5 issues
            ((issue_counter++))
            if [ $((issue_counter % 5)) -eq 0 ]; then
                check_rate_limit
            fi
        else
            echo "Issue with already exists. Skipping creation."
        fi
    done < <(tail -n +2 "$file")

done

echo "Script completed. Total issues created: $issue_counter"

