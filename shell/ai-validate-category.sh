#!/bin/bash

set -euo pipefail

# Disable output buffering
export PYTHONUNBUFFERED=1
stty -icanon 2>/dev/null || true

# Initialize counters early
validated_count=0
belongs_count=0
not_belongs_count=0

# Trap to show summary on exit
trap 'echo ""; echo "Script interrupted. Partial results: validated=$validated_count, belongs=$belongs_count, not_belongs=$not_belongs_count"' EXIT INT TERM

# Parse flags
FORCE_REVALIDATE=false
ARGS=()

for arg in "$@"; do
    if [[ "$arg" == "--force" ]] || [[ "$arg" == "-f" ]]; then
        FORCE_REVALIDATE=true
    elif [[ "$arg" == "-h" ]] || [[ "$arg" == "--help" ]]; then
        echo "AI Category Validation Script"
        echo ""
        echo "Uses OpenAI's ChatGPT API to validate if issues belong to their assigned categories."
        echo ""
        echo "Usage:"
        echo "  $0 [--force]                           # Validate all issues in all categories"
        echo "  $0 [--force] <category>                # Validate all issues in specified category"
        echo "  $0 [--force] <issue_number>            # Validate specific issue (all its categories)"
        echo "  $0 [--force] <category> <issue_number> # Validate specific issue for specific category"
        echo ""
        echo "Options:"
        echo "  --force, -f    Force re-validation of issues that already have AI labels"
        echo ""
        echo "Examples:"
        echo "  $0                       # Validate all unvalidated issues"
        echo "  $0 CitizenScience        # Validate all unvalidated CitizenScience issues"
        echo "  $0 123                   # Validate issue #123 if not already validated"
        echo "  $0 --force 123           # Re-validate issue #123 even if already validated"
        echo "  $0 eDNA 456              # Validate issue #456 for eDNA category only"
        echo ""
        echo "Categories: CitizenScience, eDNA, Tracking, Gridded"
        echo ""
        echo "Labels applied:"
        echo "  - ai-add-category: Issue belongs to the category (should be added)"
        echo "  - ai-close-issue: Issue does NOT belong to the category (should be removed)"
        echo "  - ai-confidence-{high|medium|low}: Confidence level of AI decision"
        echo ""
        echo "Requirements:"
        echo "  - OPENAI_API_KEY environment variable must be set"
        echo "  - Commands required: gh, jq, curl"
        exit 0
    else
        ARGS+=("$arg")
    fi
done

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

# Function to create label if it doesn't exist
create_label_if_missing() {
    local label_name="$1"
    local label_color="$2"
    local label_description="$3"
    
    # Check if label exists
    if ! gh label list --limit 1000 | grep -q "^${label_name}"; then
        echo "Creating missing label: $label_name"
        gh label create "$label_name" --color "$label_color" --description "$label_description" 2>/dev/null || true
    fi
}

# Ensure required labels exist
# echo "Checking for required labels..."
# create_label_if_missing "ai-add-category" "0E8A16" "AI validated: dataset belongs to this category"
# create_label_if_missing "ai-close-issue" "D93F0B" "AI validated: dataset does NOT belong to this category"
# create_label_if_missing "ai-confidence-high" "0075CA" "AI confidence level: high"
# create_label_if_missing "ai-confidence-medium" "FEF2C0" "AI confidence level: medium"
# create_label_if_missing "ai-confidence-low" "FBCA04" "AI confidence level: low"
# echo "Label check complete."
# echo ""

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

# Function to get category description
get_category_description() {
    local category="$1"
    
    case "$category" in
        "CitizenScience")
            echo "Datasets collected by volunteers, amateur naturalists, or public participation projects (e.g., iNaturalist, eBird, community science). IMPORTANT: Exclude datasets that have a professional component - only include pure citizen science where data collection is primarily done by non-professional volunteers."
            ;;
        "eDNA")
            echo "Environmental DNA datasets from metabarcoding, metagenomics, or other molecular methods. This includes microbiome studies."
            ;;
        "Tracking")
            echo "Animal tracking data including GPS, telemetry, satellite tracking, biologging, or migration studies"
            ;;
        "Gridded")
            echo "Systematically sampled data using grid-based sampling methods"
            ;;
        *)
            echo "Unknown category"
            ;;
    esac
}

# Function to call OpenAI API to validate if issue belongs to category
validate_category_match() {
    local title="$1"
    local description="$2"
    local category="$3"
    local datasetKey="$4"
    local category_desc=$(get_category_description "$category")
    
    echo "[DEBUG] Building prompt for category: $category" >&2
    
    # Build the prompt
    local prompt="You are a biodiversity data expert. Determine if the following dataset belongs to the specified category.

Category: ${category}
Category Definition: ${category_desc}

Dataset Title: ${title}

Dataset Description: ${description}

GBIF Dataset Link: https://www.gbif.org/dataset/${datasetKey}

Based on the dataset information, does this dataset belong to the ${category} category?

Respond ONLY with a JSON object in this exact format:
{
  \"belongs\": true|false,
  \"confidence\": \"high|medium|low\",
  \"reasoning\": \"Brief explanation of why it does or does not belong to this category\"
}

Be strict in your evaluation - only return true if the dataset clearly fits the category definition."

    echo "[DEBUG] Prompt built, preparing API call..." >&2
    
    # Call OpenAI API
    echo "[DEBUG] Making curl request to OpenAI..." >&2
    local response=$(curl -s --max-time 60 https://api.openai.com/v1/chat/completions \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "{
            \"model\": \"gpt-4o-mini\",
            \"messages\": [{\"role\": \"user\", \"content\": $(echo "$prompt" | jq -Rs .)}],
            \"temperature\": 0.3,
            \"max_tokens\": 300
        }" 2>&1)
    
    local curl_exit=$?
    echo "[DEBUG] Curl completed with exit code: $curl_exit" >&2
    
    if [ $curl_exit -ne 0 ]; then
        echo "ERROR: curl command failed with exit code $curl_exit (timeout or network error)" >&2
        echo "Curl output: $response" >&2
        echo "{\"belongs\": null, \"confidence\": \"unknown\", \"reasoning\": \"Network error or timeout\"}"
        return 1
    fi
    
    echo "[DEBUG] Response received, checking for errors..." >&2
    local error_message=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$error_message" ]; then
        echo "ERROR: OpenAI API error: $error_message" >&2
        echo "{\"belongs\": null, \"confidence\": \"unknown\", \"reasoning\": \"API Error: $error_message\"}"
        return 1
    fi
    
    echo "[DEBUG] No errors, extracting AI response..." >&2
    # Extract the response
    local ai_response=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    
    if [ -z "$ai_response" ]; then
        echo "ERROR: Empty response from OpenAI API" >&2
        echo "Full API response: $response" >&2
        echo "{\"belongs\": null, \"confidence\": \"unknown\", \"reasoning\": \"Empty API response\"}"
        return 1
    fi
    
    echo "[DEBUG] AI response extracted successfully" >&2
    echo "$ai_response"
}

# Parse command-line arguments
CATEGORY_FILTER="${ARGS[0]:-}"
ISSUE_NUMBER="${ARGS[1]:-}"

# Check if first argument is a number (issue number)
if [[ "$CATEGORY_FILTER" =~ ^[0-9]+$ ]]; then
    ISSUE_NUMBER="$CATEGORY_FILTER"
    CATEGORY_FILTER=""
fi

# Determine mode
if [ -n "$ISSUE_NUMBER" ]; then
    echo "Starting AI category validation for issue #$ISSUE_NUMBER"
    SINGLE_ISSUE_MODE=true
else
    SINGLE_ISSUE_MODE=false
    if [ -n "$CATEGORY_FILTER" ]; then
        echo "Starting AI category validation for category: $CATEGORY_FILTER"
        categories=("$CATEGORY_FILTER")
    else
        echo "Starting AI category validation for all categories..."
        categories=("CitizenScience" "eDNA" "Tracking" "Gridded")
    fi
fi

check_rate_limit

# Handle single issue mode
if [ "$SINGLE_ISSUE_MODE" = true ]; then
    echo ""
    echo "=========================================="
    echo "Processing single issue #$ISSUE_NUMBER"
    echo "=========================================="
    
    # Fetch the specific issue
    issue_json=$(gh issue view "$ISSUE_NUMBER" --json number,title,body,labels,state 2>/dev/null || echo "")
    
    if [ -z "$issue_json" ]; then
        echo "Error: Issue #$ISSUE_NUMBER not found or not accessible."
        exit 1
    fi
    
    issue_state=$(echo "$issue_json" | jq -r '.state')
    if [ "$issue_state" != "OPEN" ]; then
        echo "Warning: Issue #$ISSUE_NUMBER is not open (state: $issue_state)."
        echo "Continuing anyway..."
    fi
    
    issue_title=$(echo "$issue_json" | jq -r '.title')
    issue_body=$(echo "$issue_json" | jq -r '.body')
    
    # Check if issue already has AI validation labels (unless forced)
    if [ "$FORCE_REVALIDATE" = false ]; then
        existing_ai_labels=$(echo "$issue_json" | jq -r '.labels[].name' | grep -E '^(ai-add-category|ai-close-issue)$' || true)
        
        if [ -n "$existing_ai_labels" ]; then
            echo "Issue #$ISSUE_NUMBER has already been AI-validated."
            echo "Existing AI labels: $(echo "$existing_ai_labels" | tr '\n' ', ' | sed 's/, $//')"
            echo ""
            echo "To re-validate this issue, use --force flag:"
            echo "  $0 --force $ISSUE_NUMBER"
            echo ""
            echo "Or remove the existing AI labels manually:"
            echo "  gh issue edit $ISSUE_NUMBER --remove-label ai-add-category"
            echo "  gh issue edit $ISSUE_NUMBER --remove-label ai-close-issue"
            exit 0
        fi
    else
        echo "Force re-validation enabled - removing existing AI labels if present..."
        # Remove existing AI labels
        gh issue edit "$ISSUE_NUMBER" --remove-label "ai-add-category" 2>/dev/null || true
        gh issue edit "$ISSUE_NUMBER" --remove-label "ai-close-issue" 2>/dev/null || true
        gh issue edit "$ISSUE_NUMBER" --remove-label "ai-confidence-high" 2>/dev/null || true
        gh issue edit "$ISSUE_NUMBER" --remove-label "ai-confidence-medium" 2>/dev/null || true
        gh issue edit "$ISSUE_NUMBER" --remove-label "ai-confidence-low" 2>/dev/null || true
    fi
    
    # Extract datasetKey from labels
    datasetKey=$(echo "$issue_json" | jq -r '.labels[].name' | \
        grep -E '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' | head -1)
    
    if [ -z "$datasetKey" ]; then
        echo "Error: No datasetKey found in labels for issue #$ISSUE_NUMBER."
        exit 1
    fi
    
    # Extract description from issue body
    description=$(echo "$issue_body" | sed -n '/## Description/,/^$/p' | sed '1d' | head -c 2000)
    
    if [ -z "$description" ]; then
        description="No description available."
    fi
    
    # Determine which categories to validate
    issue_categories=$(echo "$issue_json" | jq -r '.labels[].name' | \
        grep -E '^(CitizenScience|eDNA|Tracking|Gridded)$')
    
    if [ -z "$issue_categories" ]; then
        echo "Error: Issue #$ISSUE_NUMBER has no category labels to validate."
        echo "Available categories: CitizenScience, eDNA, Tracking, Gridded"
        exit 1
    fi
    
    # If category filter is specified, only validate that category
    if [ -n "$CATEGORY_FILTER" ]; then
        if echo "$issue_categories" | grep -q "^${CATEGORY_FILTER}$"; then
            issue_categories="$CATEGORY_FILTER"
        else
            echo "Error: Issue #$ISSUE_NUMBER does not have the '$CATEGORY_FILTER' label."
            echo "Issue has these category labels: $(echo "$issue_categories" | tr '\n' ', ' | sed 's/, $//')"
            exit 1
        fi
    fi
    
    echo "Issue has category labels: $(echo "$issue_categories" | tr '\n' ', ' | sed 's/, $//')"
    echo ""
    
    # Validate against each category label
    while IFS= read -r category; do
        [ -z "$category" ] && continue
        
        echo "=========================================="
        echo "Validating against category: $category"
        
        echo "Calling OpenAI API for validation..."
        ai_response=$(validate_category_match "$issue_title" "$description" "$category" "$datasetKey")
        
        echo "AI Response: $ai_response"
        
        # Parse the AI response
        belongs=$(echo "$ai_response" | jq -r '.belongs' 2>/dev/null || echo "null")
        confidence=$(echo "$ai_response" | jq -r '.confidence' 2>/dev/null || echo "unknown")
        reasoning=$(echo "$ai_response" | jq -r '.reasoning' 2>/dev/null || echo "No reasoning provided")
        
        if [ "$belongs" == "null" ]; then
            echo "ERROR: Could not parse AI response. Expected JSON with 'belongs' field."
            echo "Raw AI response: $ai_response"
            echo "Skipping this category."
            continue
        fi
        
        # Apply labels based on AI decision
        if [ "$belongs" == "true" ]; then
            echo "✓ AI confirms this issue belongs to $category"
            echo "Adding label: ai-add-category"
            gh issue edit "$ISSUE_NUMBER" --add-label "ai-add-category"
            gh issue edit "$ISSUE_NUMBER" --add-label "ai-confidence-${confidence}"
            
            # Add comment
            comment="🤖 **AI Category Validation**

**Category:** ${category}
**Decision:** ✅ Belongs to category
**Confidence:** ${confidence}

**Reasoning:** ${reasoning}

_This dataset has been validated by AI to belong to the ${category} category. The issue can be reviewed for addition to the category._"
            
            belongs_count=$((belongs_count + 1))
        else
            echo "✗ AI suggests this issue does NOT belong to $category"
            echo "Adding label: ai-close-issue"
            gh issue edit "$ISSUE_NUMBER" --add-label "ai-close-issue"
            gh issue edit "$ISSUE_NUMBER" --add-label "ai-confidence-${confidence}"
            
            # Add comment
            comment="🤖 **AI Category Validation**

**Category:** ${category}
**Decision:** ❌ Does NOT belong to category
**Confidence:** ${confidence}

**Reasoning:** ${reasoning}

_This dataset has been validated by AI to NOT belong to the ${category} category. Please review. If the AI is incorrect, you may remove the 'ai-close-issue' label and keep the category._"
            
            not_belongs_count=$((not_belongs_count + 1))
        fi
        
        gh issue comment "$ISSUE_NUMBER" --body "$comment"
        
        echo "Successfully validated category $category for issue #$ISSUE_NUMBER"
        echo ""
        
        validated_count=$((validated_count + 1))
        
        # Add a small delay between categories
        sleep 2
    done <<< "$issue_categories"
    
    echo "=========================================="
    echo "Validation complete for issue #$ISSUE_NUMBER"
    echo "Categories validated: $(echo "$issue_categories" | tr '\n' ', ' | sed 's/, $//')"
    exit 0
fi

# Process each category
for category in "${categories[@]}"; do
    echo ""
    echo "=========================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processing category: $category"
    echo "=========================================="
    
    # Get all open issues with this category label (excluding those already validated)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fetching issues labeled with '$category' (not yet AI-validated)..."
    echo "[DEBUG] Running gh issue list command..."
    issues=$(gh issue list --state open --label "$category" --limit 1000 --json number,title,body,labels | \
        jq -r --arg cat "$category" '.[] | 
        select(.labels | map(.name) | 
        (any(. == "ai-add-category") or any(. == "ai-close-issue")) | not) | 
        @json')
    
    if [ -z "$issues" ]; then
        echo "No unvalidated issues found for category '$category'."
        continue
    fi
    
    issue_count=$(echo "$issues" | wc -l)
    echo "Found $issue_count issues to validate. Processing..."
    echo "[DEBUG] Starting while loop to process issues..."
    echo "[DEBUG] First few chars of issues data: $(echo "$issues" | head -c 200)"
    current_issue=0
    
    while IFS= read -r issue_json; do
        echo "[DEBUG] Read issue JSON from list"
        echo "[DEBUG] issue_json length: ${#issue_json}"
        echo "[DEBUG] current_issue before increment: $current_issue"
        
        # Skip empty lines
        if [ -z "$issue_json" ]; then
            echo "[DEBUG] Skipping empty line"
            continue
        fi
        
        current_issue=$((current_issue + 1))
        echo "[DEBUG] current_issue after increment: $current_issue"
        echo ""
        echo "=========================================="
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processing issue $current_issue of $issue_count"
        echo "=========================================="
        
        issue_number=$(echo "$issue_json" | jq -r '.number')
        issue_title=$(echo "$issue_json" | jq -r '.title')
        issue_body=$(echo "$issue_json" | jq -r '.body')
        
        echo "Issue #$issue_number: $issue_title"
        echo "Category: $category"
        
        # Extract datasetKey from labels
        echo "[DEBUG] Extracting datasetKey from labels..."
        datasetKey=$(echo "$issue_json" | jq -r '.labels[].name' | \
            grep -E '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' | head -1 || true)
        
        echo "[DEBUG] datasetKey: '$datasetKey'"
        
        if [ -z "$datasetKey" ]; then
            echo "Warning: No datasetKey found in labels for issue #$issue_number. Skipping."
            continue
        fi
        
        # Extract description from issue body
        description=$(echo "$issue_body" | sed -n '/## Description/,/^$/p' | sed '1d' | head -c 2000)
        
        if [ -z "$description" ]; then
            description="No description available."
        fi
        
        echo "Dataset Key: $datasetKey"
        echo "Description length: ${#description} characters"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Calling OpenAI API for validation..."
        echo "[DEBUG] About to call validate_category_match function"
        
        set +e  # Don't exit on error for API call
        ai_response=$(validate_category_match "$issue_title" "$description" "$category" "$datasetKey")
        api_exit_code=$?
        set -e
        
        echo "[DEBUG] validate_category_match returned with exit code: $api_exit_code"
        
        if [ $api_exit_code -ne 0 ]; then
            echo "ERROR: OpenAI API call failed with exit code $api_exit_code"
            echo "Response: $ai_response"
            echo "Skipping this issue."
            continue
        fi
        
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] AI Response received"
        echo "AI Response: $ai_response"
        
        # Parse the AI response
        belongs=$(echo "$ai_response" | jq -r '.belongs' 2>/dev/null || echo "null")
        confidence=$(echo "$ai_response" | jq -r '.confidence' 2>/dev/null || echo "unknown")
        reasoning=$(echo "$ai_response" | jq -r '.reasoning' 2>/dev/null || echo "No reasoning provided")
        
        if [ "$belongs" == "null" ]; then
            echo "ERROR: Could not parse AI response for issue #$issue_number. Expected JSON with 'belongs' field."
            echo "Raw AI response: $ai_response"
            echo "Skipping."
            continue
        fi
        
        # Apply labels based on AI decision
        if [ "$belongs" == "true" ]; then
            echo "✓ AI confirms this issue belongs to $category"
            echo "Adding label: ai-add-category"
            if ! gh issue edit "$issue_number" --add-label "ai-add-category" 2>/dev/null; then
                echo "Warning: Failed to add ai-add-category label to issue #$issue_number"
            fi
            if ! gh issue edit "$issue_number" --add-label "ai-confidence-${confidence}" 2>/dev/null; then
                echo "Warning: Failed to add confidence label to issue #$issue_number"
            fi
            
            # Add comment
            comment="🤖 **AI Category Validation**

**Category:** ${category}
**Decision:** ✅ Belongs to category
**Confidence:** ${confidence}

**Reasoning:** ${reasoning}

_This dataset has been validated by AI to belong to the ${category} category. The issue can be reviewed for addition to the category._"
            
            belongs_count=$((belongs_count + 1))
        else
            echo "✗ AI suggests this issue does NOT belong to $category"
            echo "Adding label: ai-close-issue"
            if ! gh issue edit "$issue_number" --add-label "ai-close-issue" 2>/dev/null; then
                echo "Warning: Failed to add ai-close-issue label to issue #$issue_number"
            fi
            if ! gh issue edit "$issue_number" --add-label "ai-confidence-${confidence}" 2>/dev/null; then
                echo "Warning: Failed to add confidence label to issue #$issue_number"
            fi
            
            # Add comment
            comment="🤖 **AI Category Validation**

**Category:** ${category}
**Decision:** ❌ Does NOT belong to category
**Confidence:** ${confidence}

**Reasoning:** ${reasoning}

_This dataset has been validated by AI to NOT belong to the ${category} category. Please review. If the AI is incorrect, you may remove the 'ai-close-issue' label and keep the category._"
            
            not_belongs_count=$((not_belongs_count + 1))
        fi
        
        if ! gh issue comment "$issue_number" --body "$comment" 2>/dev/null; then
            echo "Warning: Failed to add comment to issue #$issue_number"
        fi
        
        echo "Successfully validated issue #$issue_number"
        
        validated_count=$((validated_count + 1))
        
        # Check rate limit every 5 issues
        if [ $((current_issue % 5)) -eq 0 ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Checking rate limit..."
            check_rate_limit
        fi
        
        # Add a small delay to avoid overwhelming the OpenAI API
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting 2 seconds before next issue..."
        sleep 2
    done <<< "$issues"
    
    echo ""
    echo "Completed processing category: $category"
done

# Clear the trap as we're exiting normally
trap - EXIT INT TERM

echo ""
echo "=========================================="
echo "AI Category Validation Summary"
echo "=========================================="
echo "Total issues validated: $validated_count"
echo "Issues confirmed (ai-add-category): $belongs_count"
echo "Issues rejected (ai-close-issue): $not_belongs_count"
echo ""
echo "Next steps:"
echo "- Review issues with 'ai-add-category' label to proceed with adding them"
echo "- Review issues with 'ai-close-issue' label to verify they should be closed/removed"
echo ""
echo "Usage examples:"
echo "  ./ai-validate-category.sh              # Validate all issues in all categories"
echo "  ./ai-validate-category.sh CitizenScience  # Validate all CitizenScience issues"
echo "  ./ai-validate-category.sh 123          # Validate issue #123 only"
echo "  ./ai-validate-category.sh CitizenScience 123  # Validate issue #123 for CitizenScience only"
