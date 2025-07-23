#!/bin/bash
echo "----------------------------------------------"
echo "Running Phala Cloud Pre-Launch Script v0.0.7"
echo "----------------------------------------------"
set -e

# Function: notify host

notify_host() {
    if command -v dstack-util >/dev/null 2>&1; then
        dstack-util notify-host -e "$1" -d "$2"
    else
        tdxctl notify-host -e "$1" -d "$2"
    fi
}

notify_host_hoot_info() {
    notify_host "boot.progress" "$1"
}

notify_host_hoot_error() {
    notify_host "boot.error" "$1"
}

# Function: Perform Docker cleanup
perform_cleanup() {
    echo "Pruning unused images"
    docker image prune -af
    echo "Pruning unused volumes"
    docker volume prune -f
    notify_host_hoot_info "docker cleanup completed"
}

# Function: Check Docker login status without exposing credentials
check_docker_login() {
    # Try to verify login status without exposing credentials
    if docker info 2>/dev/null | grep -q "Username"; then
        return 0
    else
        return 1
    fi
}

# Main logic starts here
echo "Starting login process..."

# Check if Docker credentials exist
if [[ -n "$DSTACK_DOCKER_USERNAME" && -n "$DSTACK_DOCKER_PASSWORD" ]]; then
    echo "Docker credentials found"
    
    # Check if already logged in
    if check_docker_login; then
        echo "Already logged in to Docker registry"
    else
        echo "Logging in to Docker registry..."
        # Login without exposing password in process list
        if [[ -n "$DSTACK_DOCKER_REGISTRY" ]]; then
            echo "$DSTACK_DOCKER_PASSWORD" | docker login -u "$DSTACK_DOCKER_USERNAME" --password-stdin "$DSTACK_DOCKER_REGISTRY"
        else
            echo "$DSTACK_DOCKER_PASSWORD" | docker login -u "$DSTACK_DOCKER_USERNAME" --password-stdin
        fi
        
        if [ $? -eq 0 ]; then
            echo "Docker login successful"
        else
            echo "Docker login failed"
            notify_host_hoot_error "docker login failed"
            exit 1
        fi
    fi
# Check if AWS ECR credentials exist
elif [[ -n "$DSTACK_AWS_ACCESS_KEY_ID" && -n "$DSTACK_AWS_SECRET_ACCESS_KEY" && -n "$DSTACK_AWS_REGION" && -n "$DSTACK_AWS_ECR_REGISTRY" ]]; then
    echo "AWS ECR credentials found"
    
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        notify_host_hoot_info "awscli not installed, installing..."
        echo "AWS CLI not installed, installing..."
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.24.14.zip" -o "awscliv2.zip"
        echo "6ff031a26df7daebbfa3ccddc9af1450 awscliv2.zip" | md5sum -c
        if [ $? -ne 0 ]; then
            echo "MD5 checksum failed"
            notify_host_hoot_error "awscli install failed"
            exit 1
        fi
        unzip awscliv2.zip &> /dev/null
        ./aws/install
        
        # Clean up installation files
        rm -rf awscliv2.zip aws
    else
        echo "AWS CLI is already installed: $(which aws)"
    fi

    # Set AWS credentials as environment variables
    export AWS_ACCESS_KEY_ID="$DSTACK_AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$DSTACK_AWS_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION="$DSTACK_AWS_REGION"
    
    # Set session token if provided (for temporary credentials)
    if [[ -n "$DSTACK_AWS_SESSION_TOKEN" ]]; then
        echo "AWS session token found, using temporary credentials"
        export AWS_SESSION_TOKEN="$DSTACK_AWS_SESSION_TOKEN"
    fi
    
    # Test AWS credentials before attempting ECR login
    echo "Testing AWS credentials..."
    if ! aws sts get-caller-identity &> /dev/null; then
        echo "AWS credentials test failed"
        notify_host_hoot_error "Invalid AWS credentials"
        exit 1
    fi

    echo "Logging in to AWS ECR..."
    aws ecr get-login-password --region $DSTACK_AWS_REGION | docker login --username AWS --password-stdin "$DSTACK_AWS_ECR_REGISTRY"
    if [ $? -eq 0 ]; then
        echo "AWS ECR login successful"
        notify_host_hoot_info "AWS ECR login successful"
    else
        echo "AWS ECR login failed"
        notify_host_hoot_error "AWS ECR login failed"
        exit 1
    fi
fi

perform_cleanup

#
# Set root password if DSTACK_ROOT_PASSWORD is set.
#
if [[ -n "$DSTACK_ROOT_PASSWORD" ]]; then
    echo "root:$DSTACK_ROOT_PASSWORD" | chpasswd
    unset $DSTACK_ROOT_PASSWORD
    echo "Root password set"
fi
if [[ -n "$DSTACK_ROOT_PUBLIC_KEY" ]]; then
    mkdir -p /root/.ssh
    echo "$DSTACK_ROOT_PUBLIC_KEY" > /root/.ssh/authorized_keys
    unset $DSTACK_ROOT_PUBLIC_KEY
    echo "Root public key set"
fi


if [[ -e /var/run/dstack.sock ]]; then
    export DSTACK_APP_ID=$(curl -s --unix-socket /var/run/dstack.sock http://dstack/Info | jq -j .app_id)
else
    export DSTACK_APP_ID=$(curl -s --unix-socket /var/run/tappd.sock http://dstack/prpc/Tappd.Info | jq -j .app_id)
fi
# Check if app-compose.json has default_gateway_domain field and DSTACK_GATEWAY_DOMAIN is not set
# If true, set DSTACK_GATEWAY_DOMAIN from app-compose.json
if [[ $(jq 'has("default_gateway_domain")' app-compose.json) == "true" && -z "$DSTACK_GATEWAY_DOMAIN" ]]; then
    export DSTACK_GATEWAY_DOMAIN=$(jq -j '.default_gateway_domain' app-compose.json)
fi
if [[ -n "$DSTACK_GATEWAY_DOMAIN" ]]; then
    export DSTACK_APP_DOMAIN=$DSTACK_APP_ID"."$DSTACK_GATEWAY_DOMAIN
fi

echo "----------------------------------------------"
echo "Script execution completed"
echo "----------------------------------------------"
