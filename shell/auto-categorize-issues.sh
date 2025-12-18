#!/bin/bash

set -euo pipefail

# Check for OpenAI API key
if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "Error: OPENAI_API_KEY environment variable is not set." >&2
    echo "Please set it with: export OPENAI_API_KEY='your-api-key'" >&2
    exit 1
fi

# Check for required commands
for cmd in gh jq curl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found." >&2
        exit 1
    fi
done

# Initialize counte
categorized_count=0

# Function to check GitHub API rate limit
check_rate_limit() {
    echo "Checking GitHub API rate limit..."
    rate_limit_response=$(gh api rate_limit)
    graphql_remaining=$(echo "$rate_limit_response" | jq -r '.resources.graphql.remaining')
    echo "GraphQL remaining: $graphql_remaining"
    
    if [ "$graphql_remaining" -lt 300 ]; then
        echo "GraphQL rate limit low ($graphql_remaining remaining). Pausing for 1 hour 10 minutes..."
        sleep 4200
        echo "Resuming after rate limit pause..."
    fi
}

# Function to call OpenAI API for categorization
categorize_dataset() {
    local title="$1"
    local description="$2"
    local datasetKey="$3"
    
    # Build the prompt
    local prompt="You are a biodiversity data expert. Based on the following dataset information, determine which category(ies) it belongs to. You can assign multiple categories if appropriate.

Available categories and their descriptions:
- **CitizenScience**: Datasets collected by volunteers, amateur naturalists, or public participation projects (e.g., iNaturalist, eBird, community science)
- **eDNA**: Environmental DNA datasets from metabarcoding, metagenomics, or other molecular methods
- **Tracking**: Animal tracking data including GPS, telemetry, satellite tracking, biologging, or migration studies
- **Gridded**: Systematically sampled data using grid-based sampling methods

Dataset Title: ${title}

Dataset Description: ${description}

GBIF Dataset Link: https://www.gbif.org/dataset/${datasetKey}

Respond ONLY with a JSON object in this exact format:
{
  \"categories\": [\"CategoryName1\", \"CategoryName2\"],
  \"confidence\": \"high|medium|low\",
  \"reasoning\": \"Brief explanation\"
}

Use only the category names: CitizenScience, eDNA, Tracking, or Gridded."

    # Call OpenAI API
    local response=$(curl -s https://api.openai.com/v1/chat/completions \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "{
            \"model\": \"gpt-4o-mini\",
            \"messages\": [{\"role\": \"user\", \"content\": $(echo "$prompt" | jq -Rs .)}],
            \"temperature\": 0.3,
            \"max_tokens\": 500
        }")
    
    # Extract the response
    local ai_response=$(echo "$response" | jq -r '.choices[0].message.content')
    echo "$ai_response"
}

echo "Starting auto-categorization script..."
check_rate_limit

# Get all open issues without any category labels (no CitizenScience, eDNA, Tracking, or Gridded labels)
echo "Fetching uncategorized open issues..."
issues=$(gh issue list --state open --limit 100 --json number,title,body,labels | jq -r '.[] | select(.labels | map(.name) | any(. == "CitizenScience" or . == "eDNA" or . == "Tracking" or . == "Gridded") | not) | @json')

if [ -z "$issues" ]; then
    echo "No uncategorized issues found."
    exit 0
fi

echo "Found uncategorized issues. Processing..."

echo "$issues" | while IFS= read -r issue_json; do
    issue_number=$(echo "$issue_json" | jq -r '.number')
    issue_title=$(echo "$issue_json" | jq -r '.title')
    issue_body=$(echo "$issue_json" | jq -r '.body')
    
    echo ""
    echo "=========================================="
    echo "Processing issue #$issue_number: $issue_title"
    
    # Extract datasetKey from labels
    datasetKey=$(echo "$issue_json" | jq -r '.labels[].name' | grep -E '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' | head -1)
    
    if [ -z "$datasetKey" ]; then
        echo "Warning: No datasetKey found in labels for issue #$issue_number. Skipping."
        continue
    fi
    
    # Extract description from issue body (it's after "## Description")
    description=$(echo "$issue_body" | sed -n '/## Description/,/^$/p' | sed '1d' | head -c 2000)
    
    if [ -z "$description" ]; then
        description="No description available."
    fi
    
    echo "Calling OpenAI API for categorization..."
    ai_response=$(categorize_dataset "$issue_title" "$description" "$datasetKey")
    
    echo "AI Response: $ai_response"
    
    # Parse the AI response
    categories=$(echo "$ai_response" | jq -r '.categories[]' 2>/dev/null || echo "")
    confidence=$(echo "$ai_response" | jq -r '.confidence' 2>/dev/null || echo "unknown")
    reasoning=$(echo "$ai_response" | jq -r '.reasoning' 2>/dev/null || echo "No reasoning provided")
    
    if [ -z "$categories" ]; then
        echo "Warning: Could not extract categories from AI response for issue #$issue_number. Skipping."
        continue
    fi
    
    # Add the suggested categories and the auto-add-category label
    echo "Adding labels to issue #$issue_number:"
    for category in $categories; do
        echo "  - $category"
        gh issue edit "$issue_number" --add-label "$category"
    done
    
    # Add auto-add-category label and confidence level
    gh issue edit "$issue_number" --add-label "auto-add-category"
    gh issue edit "$issue_number" --add-label "confidence-${confidence}"
    
    # Add a comment with the reasoning
    comment="🤖 **Auto-categorization**

**Suggested Categories:** $(echo "$categories" | tr '\n' ', ' | sed 's/, $//')
**Confidence:** ${confidence}

**Reasoning:** ${reasoning}

_This categorization was automatically suggested by AI. Please review and adjust if needed._"
    
    gh issue comment "$issue_number" --body "$comment"
    
    echo "Successfully categorized issue #$issue_number"
    
    ((categorized_count++))
    
    # Check rate limit every 5 issues
    if [ $((categorized_count % 5)) -eq 0 ]; then
        check_rate_limit
    fi
    
    # Add a small delay to avoid overwhelming the OpenAI API
    sleep 2
done

echo ""
echo "=========================================="
echo "Auto-categorization completed. Total issues categorized: $categorized_count"
