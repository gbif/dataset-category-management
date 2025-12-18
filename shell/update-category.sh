#!/usr/bin/env bash

# bash shell/update-category.sh 94760e8a-7ff8-415d-9352-ab3378d8215a eDNA 1

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
# api="http://api.gbif-test.org/v1/dataset"
api="http://api.gbif.org/v1/dataset"

# Validate uuid_dataset is a UUID
if ! [[ "$uuid_dataset" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "Provided dataset_uuid '$uuid_dataset' is not a valid UUID."
  exit 1
fi

# Validate category is non-empty
if [ -z "$category" ]; then
  echo "Category must be a non-empty string."
  exit 1
fi

# Validate github_issue is a numbe
if ! [[ "$github_issue" =~ ^[0-9]+$ ]]; then
  echo "github_issue must be a numeric value."
  exit 1
fi

# 1. Fetch dataset
http_status=$(curl -s -o dataset.json -w "%{http_code}" -u "$GBIF_USER:$GBIF_PWD" "$api/$uuid_dataset")
if [ "$http_status" -ne 200 ]; then
  echo "Failed to fetch dataset $uuid_dataset (HTTP $http_status)"
  exit 1
fi
dataset_json=$(cat dataset.json)
rm -f dataset.json
# echo $dataset_json | jq .

key_count_start=$(echo "$dataset_json" | jq 'keys | length')
if [ "$key_count_start" -eq 0 ]; then
  echo "No top-level keys found in dataset_json. Exiting."
  exit 1
fi

# Check if any category exists - continue processing instead of exiting
category_count=$(echo "$dataset_json" | jq '.category | length // 0')
if [ "$category_count" -gt 0 ]; then
  echo "Categories exist for dataset $uuid_dataset. Will append new category $category."
  echo "Current categories:"
  echo "$dataset_json" | jq '.category'
  
  # Check if the category already exists
  category_exists=$(echo "$dataset_json" | jq --arg cat "$category" '.category | contains([$cat])')
  if [ "$category_exists" = "true" ]; then
    echo "Category '$category' already exists. No changes needed."
    exit 0
  fi
  
  # Append the new category to existing ones
  dataset_json=$(echo "$dataset_json" | jq --arg cat "$category" '.category += [$cat]')
  echo "Updated categories:"
  echo "$dataset_json" | jq '.category'
else
  echo "No categories exist for dataset $uuid_dataset. Adding category $category."
  echo "current categories:"
  echo "$dataset_json" | jq '.category'
  
  # Add the category field with the new category
  dataset_json=$(echo "$dataset_json" | jq --arg cat "$category" '.category = [$cat]')
  echo "Updated dataset_json with new category:"
  echo "$dataset_json" | jq '.category'
fi

# Tests to make sure we got valid JSON so we don't overwrite 
# with gibberish 
if [ -z "$dataset_json" ]; then
  echo "Failed to fetch dataset $uuid_dataset"
  exit 1
else
  echo "Successfully fetched dataset $uuid_dataset"
fi

# Test that dataset_json is valid JSON
echo "$dataset_json" | jq empty
if [ $? -ne 0 ]; then
  echo "Fetched data is not valid JSON. Exiting."
  exit 1
else
  echo "Fetched data is valid JSON."
fi

# Check if 'key' in dataset_json is a valid UUID
dataset_key=$(echo "$dataset_json" | jq -r '.key // empty')
if ! [[ "$dataset_key" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "'key' in dataset_json is not a valid UUID. Exiting."
  exit 1
else
  echo "'key' in dataset_json is a valid UUID."
fi

# Check that updated_json is valid JSON
echo "$dataset_json" | jq empty
if [ $? -ne 0 ]; then
  echo "dataset_json is not valid JSON. Exiting."
  exit 1
else
  echo "dataset_json is valid JSON."
fi

# echo $dataset_json | jq . 
# echo "$dataset_json" | jq -r 'keys[]'

# Get the number of top-level keys in dataset_json
key_count_final=$(echo "$dataset_json" | jq 'keys | length')
echo "Number of top-level keys: $key_count_final"

# Update key count validation - only expect increase if category field didn't exist
has_category=$(echo "$dataset_json" | jq 'has("category")')
if [ "$has_category" = "true" ] && [ "$category_count" -eq 0 ]; then
  expected_count=$((key_count_start + 1))
else
  expected_count=$key_count_start
fi

if [ "$key_count_final" -ne "$expected_count" ]; then
  echo "Unexpected number of top-level keys: expected $expected_count, got $key_count_final"
  exit 1
fi

# Ensure key_count_final is greater than zero
if [ "$key_count_final" -le 0 ]; then
  echo "Final key count is not greater than zero. Exiting."
  exit 1
fi

echo $dataset_json | jq .

resp=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$GBIF_USER:$GBIF_PWD" \
  -H "Content-Type: application/json" \
  -X PUT \
  -d "$dataset_json" \
  "$api/$uuid_dataset")

echo "Response code from dataset update: $resp"

if [ "$resp" -eq 204 ]; then
  echo "dataset updated with category $category"
else
  echo "dataset NOT updated"
  exit 1
fi

# 2. Add comment
comment_json=$(jq -n --arg c "$comment" '{content: $c}')
echo "$comment_json" | jq .
resp=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$GBIF_USER:$GBIF_PWD" \
  -H "Content-Type: application/json" \
  -d "$comment_json" \
  "$api/$uuid_dataset/comment")

if [ "$resp" -eq 204 ] || [ "$resp" -eq 201 ]; then
  echo "comment added"
else
  echo "Comment could NOT be added"
  exit 1
fi

trap 'echo "An error occurred. Exiting."; exit 1' ERR


