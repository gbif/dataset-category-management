# Remove category from dataset

set -euo pipefail

# Check for required commands
for cmd in curl jq; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "Error: Required command '$cmd' not found."
    exit 1
  fi
done

# check that required environment variables are set
if [ -z "${GBIF_USER:-}" ] || [ -z "${GBIF_PWD:-}" ]; then
  echo "Error: GBIF_USER and GBIF_PWD environment variables must be set."
  exit 1
fi

# Check for valid input arguments
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
  echo "Error : Missing arguments."
  echo "Usage: $0 <dataset_uuid> <category> <github_issue>"
  exit 1
fi

uuid_dataset="$1"
category="$2"
github_issue="$3"
comment="https://github.com/gbif/dataset-category-management/issues/$github_issue"
api="http://api.gbif-test.org/v1/dataset"


# remove_category="eDNA" # Set this to the category you want to remove
# uuid_dataset="94760e8a-7ff8-415d-9352-ab3378d8215a"
# category="eDNA"
# comment="https://github.com/gbif/dataset-category-management/issues/"$github_issue
# api="http://api.gbif-test.org/v1/dataset"

# dataset_json=$(curl -s -u "$GBIF_USER:$GBIF_PWD" "$api/$uuid_dataset")

# Check if category exists
category_exists=$(echo "$dataset_json" | jq --arg cat "$remove_category" '.category // [] | index($cat)')
if [ "$category_exists" = "null" ]; then
  echo "Category '$remove_category' does not exist for dataset $uuid_dataset"
  exit 0
fi

updated_json=$(echo "$dataset_json" | \
  jq --arg cat "$remove_category" '
    .category = (.category // [] | map(select(. != $cat)))
  ')

echo $updated_json | jq .

resp=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$GBIF_USER:$GBIF_PWD" \
  -H "Content-Type: application/json" \
  -X PUT \
  -d "$updated_json" \
  "$api/$uuid_dataset")

if [ "$resp" -eq 204 ]; then
  echo "category removed"
else
  echo "category NOT removed"
fi

dataset_json2=$(curl -s -u "$GBIF_USER:$GBIF_PWD" "$api/$uuid_dataset")
echo $dataset_json2 | jq .


