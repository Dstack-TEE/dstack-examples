#!/bin/bash

# Configuration variables with default values
IMAGE_VERSION="0.5.1"
VCPU_COUNT="2"
MEM_SIZE="2048"

# The dstack-vmm RPC endpoint
# VMM_URL="http://localhost:12000"

# The dstack-gateway base domain
# GATEWAY_BASE_DOMAIN="app.kvin.wang:12004"

DCAP_QVL_DL_URL="https://github.com/Phala-Network/dcap-qvl/releases/download/v0.2.4/dcap-qvl-linux-amd64"
DSTACK_MR_DL_URL="https://github.com/kvinwang/dstack-mr/releases/download/v0.5.0/dstack-mr-linux-amd64"
IMAGE_DL_URL="https://github.com/Dstack-TEE/meta-dstack/releases/download/v${IMAGE_VERSION}/dstack-${IMAGE_VERSION}.tar.gz"

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${THIS_DIR}/work"
IMAGES_DIR="${WORK_DIR}/images"
TOOLS_DIR="${WORK_DIR}/bin"


# Function to display usage information
usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  download    Downloads the materials required for verification (image, tools)"
    echo "  compose     Prepare app-compose.json to be deployed"
    echo "  calc-mrs    Calculate the known good MRs before deployment"
    echo "  deploy      Deploy the app"
    echo "  verify      Request quote from the app and verify the attestation"
    echo ""
    exit 1
}

# Function to check if required variables are set
check_required_vars() {
    local missing_vars=false

    if [ -z "$VMM_URL" ]; then
        echo "Error: VMM_URL is not set"
        missing_vars=true
    fi

    if [ -z "$GATEWAY_BASE_DOMAIN" ]; then
        echo "Error: GATEWAY_BASE_DOMAIN is not set"
        missing_vars=true
    fi

    if [ -z "$DCAP_QVL_DL_URL" ]; then
        echo "Error: DCAP_QVL_DL_URL is not set"
        missing_vars=true
    fi

    if [ -z "$DSTACK_MR_DL_URL" ]; then
        echo "Error: DSTACK_MR_DL_URL is not set"
        missing_vars=true
    fi

    if [ "$missing_vars" = true ]; then
        echo "Please set the missing variables as environment variables"
        exit 1
    fi
}

# Command: download - Downloads the materials required for verification
download_command() {
    echo "Downloading materials required for verification..."

    # Check if curl command exists
    if ! command -v curl &> /dev/null; then
        echo "Error: curl command not found. Please install it first."
        exit 1
    fi

    # Create images directory
    mkdir -p "${IMAGES_DIR}" "${TOOLS_DIR}"

    # Download DCAP QVL tool
    echo "Downloading DCAP QVL tool from $DCAP_QVL_DL_URL"
    curl -L "$DCAP_QVL_DL_URL" -o "${TOOLS_DIR}/dcap-qvl"
    chmod +x "${TOOLS_DIR}/dcap-qvl"

    # Download Dstack MR tool
    echo "Downloading Dstack MR tool from $DSTACK_MR_DL_URL"
    curl -L "$DSTACK_MR_DL_URL" -o "${TOOLS_DIR}/dstack-mr"
    chmod +x "${TOOLS_DIR}/dstack-mr"

    # Download and extract image
    echo "Downloading Dstack image..."
    local image_url="${IMAGE_DL_URL}"
    local image_filename="$(basename "${image_url}")"
    local image_path="${IMAGES_DIR}/${image_filename}"

    echo "Downloading image from ${image_url}"
    curl -L "${image_url}" -o "${image_path}"

    if [ $? -eq 0 ]; then
        echo "Extracting image..."
        tar -xzf "${image_path}" -C "${IMAGES_DIR}"
        if [ $? -eq 0 ]; then
            echo "Image extracted successfully"
            rm "${image_path}"
        else
            echo "Error: Failed to extract image"
        fi
    else
        echo "Error: Failed to download image"
    fi

    echo "Downloads completed successfully"
}

# Command: compose - Prepare app-compose.json to be deployed
compose_command() {
    echo "Preparing app-compose.json for deployment..."

    # Check if jq command exists
    if ! command -v jq &> /dev/null; then
        echo "Error: jq command not found. Please install it first."
        exit 1
    fi

    # Check if docker-compose.yaml exists
    if [ ! -f "../docker-compose.yaml" ]; then
        echo "Error: docker-compose.yaml not found in the current directory."
        exit 1
    fi

    # Generate app-compose.json
    echo "Generating app-compose.json"

    # Create app-compose.json with proper structure
    cat > "app-compose.json" << EOF
{
    "manifest_version": 2,
    "name": "dstack-attestation-example",
    "runner": "docker-compose",
    "docker_compose_file": $(jq -Rs . < ../docker-compose.yaml),
    "kms_enabled": true,
    "gateway_enabled": true,
    "local_key_provider_enabled": false,
    "key_provider_id": "",
    "public_logs": true,
    "public_sysinfo": true,
    "allowed_envs": [],
    "no_instance_id": false,
    "secure_time": false
}
EOF
    # Calculate compose hash
    COMPOSE_HASH=$(sha256sum app-compose.json | cut -d' ' -f1)
    echo "app-compose.json has been prepared and is ready for deployment"
    echo "Compose hash: ${COMPOSE_HASH}"
}

# Command: calc-mrs - Calculate the known good MRs before deployment
calc_mrs_command() {
    echo "Calculating known good MRs before deployment..."

    # Check if the tools are downloaded
    if [ ! -d "$TOOLS_DIR" ] || [ -z "$(ls -A "$TOOLS_DIR")" ]; then
        echo "Error: Tools not found. Run '$0 download' first."
        exit 1
    fi

    # Check if app-compose.json exists
    if [ ! -f "app-compose.json" ]; then
        echo "Error: app-compose.json not found. Run '$0 compose' first."
        exit 1
    fi

    # Check if image files exist
    if [ ! -d "${IMAGES_DIR}/dstack-${IMAGE_VERSION}" ]; then
        echo "Error: Dstack image not found. Run '$0 download' first."
        exit 1
    fi

    # Calculate mr_config_id from app-compose.json and pad to 48 bytes (96 hex characters)
    original_hash=$(sha256sum app-compose.json | cut -d' ' -f1)
    # Pad with zeros if needed to reach 96 characters
    mr_config_id=$(printf "%-96s" "$original_hash" | tr ' ' '0')
    echo "Using mr_config_id: $mr_config_id"

    # Run dstack-mr with metadata.json from the image
    echo "Running dstack-mr to calculate MRs..."
    ${TOOLS_DIR}/dstack-mr -metadata "${IMAGES_DIR}/dstack-${IMAGE_VERSION}/metadata.json" \
                       -cpu ${VCPU_COUNT} \
                       -memory "${MEM_SIZE}M" \
                       -json > "known_good_mrs.json.tmp"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to calculate MRs"
        exit 1
    fi
    # Add mr_config_id to the JSON object
    jq --arg mr_config_id "$mr_config_id" '. + {"mr_config_id": $mr_config_id}' "known_good_mrs.json.tmp" > "known_good_mrs.json"

    echo "MRs calculation completed. Results saved to known_good_mrs.json"
}

# Command: deploy - Deploy the app
deploy_command() {
    echo "Deploying app..."

    if [ ! -f "app-compose.json" ]; then
        echo "Error: app-compose.json not found. Run '$0 compose' first."
        exit 1
    fi

    # Generate request.json with VmConfiguration structure
    cat > "request.json" << EOF
{
    "name": "dstack-attestation-example",
    "image": "dstack-${IMAGE_VERSION}",
    "compose_file": $(jq -Rs . < app-compose.json),
    "vcpu": ${VCPU_COUNT},
    "memory": ${MEM_SIZE},
    "disk_size": 10
}
EOF

    # Deploy the app
    echo "Deploying app..."
    HTTP_STATUS=$(curl -s -w "%{http_code}" -X POST "${VMM_URL}/prpc/CreateVm" \
        -H "Content-Type: application/json" \
        -d @"request.json" -o "vm-id.json")

    if [[ $HTTP_STATUS -ge 200 && $HTTP_STATUS -lt 300 ]]; then
        echo "✅ App deployed successfully!"
    else
        echo "❌ Failed to deploy app! (HTTP Status: $HTTP_STATUS)"
        cat vm-id.json
        exit 1
    fi
    vm_id=$(jq -r '.id' vm-id.json)
    echo "VM ID: $vm_id"
    echo "Waiting for the app to start..."
    while true; do
        HTTP_STATUS=$(curl -s -w "%{http_code}" -X GET "${VMM_URL}/prpc/GetInfo?id=$vm_id" -o vm-info.json)
        if [[ $HTTP_STATUS -ge 200 && $HTTP_STATUS -lt 300 ]]; then
            instance_id=$(jq -r '.info.instance_id // empty' vm-info.json)
            if [ -n "$instance_id" ]; then
                echo "✅ App started successfully!"
                echo "Instance ID: $instance_id"
                echo $instance_id > instance_id.txt
                break
            fi
            # Check for boot errors
            boot_error=$(jq -r '.info.boot_error // empty' vm-info.json)
            if [ -n "$boot_error" ]; then
                echo "❌ App failed to start! Error: $boot_error"
                exit 1
            fi
            # Check boot progress
            boot_progress=$(jq -r '.info.boot_progress // empty' vm-info.json)
            echo "Boot progress: $boot_progress"
            # Continue waiting
        fi
        sleep 1
    done
}

# Command: verify - Request quote from the app and verify the attestation
verify_command() {
    echo "Requesting quote from the app and verifying attestation..."

    # Check if known good MRs exist
    if [ ! -f "known_good_mrs.json" ]; then
        echo "Error: Known good MRs not found. Run '$0 calc-mrs' first."
        exit 1
    fi

    if [ ! -f "instance_id.txt" ]; then
        echo "Error: Instance ID not found. Run '$0 deploy' first."
        exit 1
    fi

    instance_id=$(cat instance_id.txt)

    # Request quote from the app
    echo "Requesting quote from ${GATEWAY_BASE_URL}/quote"
    HTTP_STATUS=$(curl -s -w "%{http_code}" -X GET "https://${instance_id}-8888.${GATEWAY_BASE_DOMAIN}/quote.json" -o "quote.json")

    if [[ $HTTP_STATUS -ge 200 && $HTTP_STATUS -lt 300 ]]; then
        echo "✅ Quote downloaded successfully!"
    else
        echo "❌ Failed to download quote! (HTTP Status: $HTTP_STATUS)"
        exit 1
    fi

    if [ ! -f "quote.json" ]; then
        echo "Error: Failed to download report from the app"
        exit 1
    fi

    jq -j '.quote' quote.json > quote.hex

    # Verify the attestation using DCAP QVL tool
    echo "Verifying attestation using DCAP QVL tool"
    "${TOOLS_DIR}/dcap-qvl" verify --hex quote.hex > report.json
    if [ $? -ne 0 ]; then
        echo "❌ Attestation verification failed!"
        exit 1
    fi
    echo "✅ Attestation verification successful!"

    status=$(jq -r '.status' report.json)
    if [ "$status" != "UpToDate" ]; then
        echo "⚠️  TCB is not up to date! status: $status"
        echo "⚠️  Advisory IDs: $(jq -r '.advisory_ids[]' report.json)"
    fi

    echo "Comparing RTMRs with known good values..."

    # Determine which TD report is available (TD10 or TD15)
    td_path=""
    if jq -e '.report.TD10' report.json > /dev/null 2>&1; then
        td_path=".report.TD10"
        echo "Using TD10 report for verification"
    elif jq -e '.report.TD15' report.json > /dev/null 2>&1; then
        td_path=".report.TD15"
        echo "Using TD15 report for verification"
    else
        echo "❌ No TD10 or TD15 report found in the response!"
        exit 1
    fi

    # Extract mr_config_id from the report
    mr_config_id=$(jq -r "${td_path}.mr_config_id // empty" report.json)
    if [ -n "$mr_config_id" ]; then
        # Compare with known good value
        known_mr_config_id=$(jq -r '.mr_config_id // empty' known_good_mrs.json)
        if [ "$mr_config_id" = "$known_mr_config_id" ]; then
            echo "✅ mr_config_id matches known good value"
        else
            echo "❌ mr_config_id does not match known good value!"
            echo "Expected: $known_mr_config_id"
            echo "Got:      $mr_config_id"
        fi
    else
        echo "⚠️ Could not extract mr_config_id from report"
    fi

    # Compare RTMRs with known good values
    for rtmr in "mr_td" "rt_mr0" "rt_mr1" "rt_mr2"; do
        report_value=$(jq -r "${td_path}.${rtmr} // empty" report.json)
        if [ -n "$report_value" ]; then
            # Convert rtmr name to the format in known_good_mrs.json (e.g., rt_mr0 -> rtmr0)
            mrs_key=${rtmr/_/}
            known_value=$(jq -r ".$mrs_key // empty" known_good_mrs.json)

            if [ -n "$known_value" ]; then
                if [ "$report_value" = "$known_value" ]; then
                    echo "✅ $rtmr matches known good value"
                else
                    echo "❌ $rtmr does not match known good value!"
                    echo "Expected: $known_value"
                    echo "Got:      $report_value"
                fi
            else
                echo "⚠️ No known good value for $rtmr"
            fi
        fi
    done
    # Print report_data for debugging
    report_data=$(jq -r "${td_path}.report_data // empty" report.json)
    if [ -n "$report_data" ]; then
        echo "Report data:"
        echo "$report_data"
    else
        echo "No report data found in the response!"
    fi
}

# Main script execution
if [ $# -eq 0 ]; then
    usage
fi

mkdir -p "${WORK_DIR}"

main() {
    # Process command
    case "$1" in
        download)
            check_required_vars
            download_command
            ;;
        compose)
            check_required_vars
            compose_command
            ;;
        calc-mrs)
            check_required_vars
            calc_mrs_command
            ;;
        deploy)
            check_required_vars
            deploy_command
            ;;
        verify)
            check_required_vars
            verify_command
            ;;
        *)
            echo "Error: Unknown command '$1'"
            usage
            ;;
    esac
}

(cd "${WORK_DIR}" && main "$@")
exit 0
