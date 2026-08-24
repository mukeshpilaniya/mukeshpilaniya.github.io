#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 [-d DATE] [-c CATEGORY] [-t TAG1,TAG2,...] <filename.md>"
    echo
    echo "Prepends a date prefix and adds Jekyll front matter to a markdown file."
    echo
    echo "Options:"
    echo "  -d DATE        Date in YYYY-MM-DD format (default: today)"
    echo "  -c CATEGORY    Category name (default: memory)"
    echo "  -t TAGS        Comma-separated tags (default: derived from filename)"
    echo
    echo "Example:"
    echo "  $0 virtual_memory_internals_part_1.md"
    echo "  $0 -d 2026-08-10 -c memory -t 'virtual memory,page tables' my_post.md"
    exit 1
}

DATE=$(date +%Y-%m-%d)
CATEGORY="memory"
TAGS=""

while getopts "d:c:t:h" opt; do
    case $opt in
        d) DATE="$OPTARG" ;;
        c) CATEGORY="$OPTARG" ;;
        t) TAGS="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [ $# -ne 1 ]; then
    usage
fi

FILENAME="$1"
DIR=$(dirname "$FILENAME")
BASE=$(basename "$FILENAME")

if [ ! -f "$FILENAME" ]; then
    echo "Error: file '$FILENAME' not found"
    exit 1
fi

if head -1 "$FILENAME" | grep -q '^---$'; then
    echo "Error: '$FILENAME' already has front matter"
    exit 1
fi

if echo "$BASE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-'; then
    echo "Error: '$BASE' already has a date prefix"
    exit 1
fi

if [ -z "$TAGS" ]; then
    TAGS=$(echo "${BASE%.md}" | tr '_' ' ')
fi

NEW_BASE="${DATE}-${BASE}"
NEW_FILE="${DIR}/${NEW_BASE}"

if [ -f "$NEW_FILE" ]; then
    echo "Error: '$NEW_FILE' already exists"
    exit 1
fi

FRONT_MATTER=$(cat <<EOF
---
published: true
categories: [$CATEGORY]
tags: [$TAGS]
---

EOF
)

{ echo "$FRONT_MATTER"; cat "$FILENAME"; } > "$NEW_FILE"
rm "$FILENAME"

echo "Created: $NEW_FILE"
