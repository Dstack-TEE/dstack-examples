#!/bin/bash

while true; do
    echo "[$(date)] Checking for certificate renewal"

    local all_domains
    all_domains=$(get-all-domains.sh)

    if [ -n "$all_domains" ]; then
        renewal_occurred=false
        while IFS= read -r domain; do
            [[ -n "$domain" ]] || continue
            echo "[$(date)] Checking renewal for domain: $domain"
            if renew-certificate.sh "$domain"; then
                renewal_occurred=true
            else
                echo "Certificate renewal check failed for $domain with status $?"
            fi
        done <<<"$all_domains"

        if [ "$renewal_occurred" = true ]; then
            echo "[$(date)] Generating evidence files after renewals..."
            generate-evidences.sh || echo "Evidence generation failed"
            if ! nginx -s reload; then
                echo "Nginx reload failed" >&2
            else
                echo "Certificate renewed and Nginx reloaded successfully"
            fi
        fi
    else
        echo "[$(date)] No domains configured for renewal"
    fi

    echo "[$(date)] Next renewal check in 12 hours"
    sleep 43200
done
