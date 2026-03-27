#!/bin/bash

while true; do
    echo "[$(date)] Checking for certificate renewal"

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

            # Rebuild combined PEM files for haproxy
            build-combined-pems.sh || echo "Combined PEM build failed"

            # Graceful reload: send SIGUSR2 to haproxy master process
            if [ ! -f /var/run/haproxy/haproxy.pid ]; then
                echo "HAProxy reload failed: PID file /var/run/haproxy/haproxy.pid not found" >&2
            elif ! kill -USR2 "$(cat /var/run/haproxy/haproxy.pid)"; then
                echo "HAProxy reload failed: SIGUSR2 to PID $(cat /var/run/haproxy/haproxy.pid) failed" >&2
            else
                echo "Certificate renewed and HAProxy reloaded successfully"
            fi
        fi
    else
        echo "[$(date)] No domains configured for renewal"
    fi

    echo "[$(date)] Next renewal check in 12 hours"
    sleep 43200
done
