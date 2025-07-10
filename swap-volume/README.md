# Swap Volume Example

This example demonstrates how to create and enable a swap volume for CVMs in a serverless cloud environment. This extends available memory beyond the physical RAM allocated to your container.

## What This Does

Creates a persistent swap file (2GB by default, configurable) that automatically activates when the container starts, providing additional virtual memory for memory-intensive applications.

## How It Works

- **Automatic Setup**: Creates a swap file on first run (configurable size, 2GB default), skips creation on subsequent restarts
- **Persistent Storage**: Swap file is stored on the CVM filesystem
- **Privileged Mode**: Required to enable swap functionality within the CVM

## Configuration

### Customizing Swap Size

Set the `SWAP_SIZE_MB` environment variable to configure swap file size in megabytes:

```bash
SWAP_SIZE_MB=1024   # 1GB
SWAP_SIZE_MB=2048   # 2GB (default)
SWAP_SIZE_MB=4096   # 4GB
SWAP_SIZE_MB=8192   # 8GB
```

You can set this when deploying to your cloud platform using environment variables or by modifying the docker-compose.yml file.

## Deployment

Deploy this docker-compose.yml to dstack or Phala Cloud. You can customize the swap size using the `SWAP_SIZE_MB` environment variable:

**Option 1: Set via platform environment variables**
Deploy the docker-compose.yml as-is and set `SWAP_SIZE_MB=4096` through your cloud platform's environment variable configuration.

**Option 2: Set directly in docker-compose.yml**
```yaml
services:
  swap-creator:
    image: alpine
    container_name: init-swap
    privileged: true
    environment:
      - SWAP_SIZE_MB=4096  # 4GB swap file
    # ... (rest of configuration)
```

## Use Cases

Ideal for:
- Memory-intensive applications that may exceed allocated RAM
- Build processes and CI/CD pipelines
- Data processing workloads
- Applications with variable memory requirements

## Security Notes

- Container runs in privileged mode (required for swap management)
- Swap file has restrictive permissions (600)
- Swap volume is isolated within the container environment

## Contributors

This example was contributed by [@bhhnjjd](https://github.com/bhhnjjd).
