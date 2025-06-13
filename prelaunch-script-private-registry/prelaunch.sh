#!/bin/bash
echo "----------------------------------------------"
echo "Running Phala Cloud Pre-Launch Script v0.0.2"
echo "----------------------------------------------"
set -e

# Function: Perform Docker cleanup
perform_cleanup() {
    echo "Pruning unused images"
    docker image prune -af
    echo "Pruning unused volumes"
    docker volume prune -f
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

# Function: Check AWS ECR login status
check_ecr_login() {
    # Check if we can access the registry without exposing credentials
    if aws ecr get-authorization-token --region $DSTACK_AWS_REGION &>/dev/null; then
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
            exit 1
        fi
    fi
# Check if AWS ECR credentials exist
elif [[ -n "$DSTACK_AWS_ACCESS_KEY_ID" && -n "$DSTACK_AWS_SECRET_ACCESS_KEY" && -n "$DSTACK_AWS_REGION" && -n "$DSTACK_AWS_ECR_REGISTRY" ]]; then
    echo "AWS ECR credentials found"
    
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        echo "AWS CLI not installed, installing..."
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.24.14.zip" -o "awscliv2.zip"
        echo "6ff031a26df7daebbfa3ccddc9af1450 awscliv2.zip" | md5sum -c
        if [ $? -ne 0 ]; then
            echo "MD5 checksum failed"
            exit 1
        fi
        unzip awscliv2.zip &> /dev/null
        ./aws/install
        
        # Clean up installation files
        rm -rf awscliv2.zip aws
    else
        echo "AWS CLI is already installed: $(which aws)"
    fi
    
    # Configure AWS CLI
    aws configure set aws_access_key_id "$DSTACK_AWS_ACCESS_KEY_ID"
    aws configure set aws_secret_access_key "$DSTACK_AWS_SECRET_ACCESS_KEY"
    aws configure set default.region $DSTACK_AWS_REGION
    echo "Logging in to AWS ECR..."
    aws ecr get-login-password --region $DSTACK_AWS_REGION | docker login --username AWS --password-stdin "$DSTACK_AWS_ECR_REGISTRY"
    if [ $? -eq 0 ]; then
        echo "AWS ECR login successful"
    else
        echo "AWS ECR login failed"
        exit 1
    fi
fi

perform_cleanup

echo "----------------------------------------------"
echo "Script execution completed"
echo "----------------------------------------------"