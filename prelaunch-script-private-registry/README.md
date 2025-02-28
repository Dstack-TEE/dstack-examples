# DStack Pre-Launch Script: Private Registry Support

## Overview

This directory contains a real-world example of a pre-launch script for DStack applications. The script demonstrates how to authenticate with private container registries (Docker Hub or AWS ECR) using encrypted environment variables before launching your application.

Pre-launch scripts were introduced in DStack v0.3.5 (as detailed in [#94](https://github.com/Dstack-TEE/dstack/pull/94)) and enable applications to perform preliminary setup steps before Docker Compose initialization.

## How It Works

The script (version v0.0.1) performs the following operations:

- Checks for specific encrypted environment variables 
- Authenticates with Docker Hub using the Docker CLI if Docker Hub credentials are provided
- Authenticates with AWS ECR using the AWS CLI if AWS credentials are provided
- Installs AWS CLI automatically if it's not available (when using AWS ECR)
- Performs Docker cleanup by pruning unused images and volumes
- Does nothing by default if no credentials are provided
- Exits with error code 1 if authentication fails

## Configuration

### Docker Hub Authentication

To authenticate with Docker Hub, configure these encrypted environment variables:

- `DSTACK_DOCKER_USERNAME` - Your Docker Hub username
- `DSTACK_DOCKER_PASSWORD` - Your Docker Hub password or access token

### AWS ECR Authentication

To authenticate with AWS ECR, configure these encrypted environment variables:

- `DSTACK_AWS_ACCESS_KEY_ID` - Your AWS access key ID
- `DSTACK_AWS_SECRET_ACCESS_KEY` - Your AWS secret access key
- `DSTACK_AWS_REGION` - The AWS region where your ECR repository is located
- `DSTACK_AWS_ECR_REGISTRY` - Your AWS ECR registry URL

## Usage

1. Set up the required encrypted environment variables for your chosen registry
2. Reference this pre-launch script in your `app-compose.json` file in the `pre_launch_script` section
3. Deploy your application using DStack

## Security Features

- The script uses `--password-stdin` when logging in to Docker to prevent credentials from appearing in process lists
- Credentials are handled securely, never exposed in logs or error messages
- For AWS ECR, the script verifies the AWS CLI installation package with MD5 checksum
- The script checks if you're already logged in to avoid unnecessary authentication attempts

## Notes

- The pre-launch script is executed before Docker Compose initialization
- No authentication is performed if the required environment variables are not provided
- The script automatically performs Docker cleanup to free up space by removing unused images and volumes
- You can modify the script to support additional private container registries as needed