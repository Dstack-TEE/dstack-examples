#!/bin/bash

# get-all-domains.sh - Returns all domains from both DOMAIN and DOMAINS environment variables
# Output: One domain per line, deduplicated

set -e

parse_domains_list() {
    local input="$1"
    if [[ "$input" == *$'\n'* ]]; then
        echo "$input" | grep -v '^#' | grep -v '^$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
    else
        echo "$input" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
    fi
}

{
    if [ -n "$DOMAIN" ]; then
        echo "$DOMAIN"
    fi

    if [ -n "$DOMAINS" ]; then
        parse_domains_list "$DOMAINS"
    fi
} | sort -u | grep -v '^$'
