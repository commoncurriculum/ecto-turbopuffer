#!/usr/bin/env bash
# Refreshes docs/turbopuffer/ with the Markdown pages turbopuffer publishes, listed in its llms.txt.
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)/docs/turbopuffer"
mkdir -p "$dir"

curl -sSf --retry 3 https://turbopuffer.com/llms.txt -o "$dir/llms.txt"

grep -o 'https://turbopuffer.com/docs/[^)]*\.md' "$dir/llms.txt" | sort -u | while read -r url; do
  curl -sSf --retry 3 "$url" -o "$dir/$(basename "$url")"
done
