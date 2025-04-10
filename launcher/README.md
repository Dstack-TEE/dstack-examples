# Dstack Launcher Pattern Example

This repository demonstrates the dstack launcher pattern - a template for implementing automated container updates in your applications.

## What is the Launcher Pattern?

The launcher pattern is a containerized approach to managing application updates. It consists of:

1. A **launcher container** that runs continuously and checks for updates
2. A **workload container** that is the actual application being managed

The launcher container periodically checks for updates to the workload container and automatically deploys new versions when they become available.

## How This Example Works

This example project demonstrates the basic structure of the launcher pattern:

- `Dockerfile`: Builds the launcher container with necessary dependencies
- `entrypoint.sh`: The main script that runs inside the launcher container, checking for updates and deploying new versions
- `get-latest.sh`: A script that determines the latest version of the workload container (in a real implementation, this would typically check a registry or other source)
- `docker-compose.yml`: Example configuration for running the launcher container

## Using This Template

This project is intended as a starting point. To adapt it for your own use:

1. Modify `get-latest.sh` to implement your own version checking logic (e.g., checking a container registry)
2. Adjust the configuration variables in `entrypoint.sh` to match your application needs
3. Update the `docker-compose.yml` file with any additional configuration your launcher needs

## Implementation Details

### Update Process

The update process follows these steps:

1. The launcher container runs `get-latest.sh` to determine the latest available version
2. If a new version is detected, it generates a new `docker-compose.yml` file for the workload
3. It applies the new configuration using Docker Compose, which pulls and starts the new container
4. The process repeats on a regular interval

### Customization Points

Key areas to customize for your own implementation:

- **Version Detection**: Replace the logic in `get-latest.sh` with your own mechanism for determining the latest version
- **Deployment Configuration**: Modify how the `docker-compose.yml` is generated in `entrypoint.sh`
- **Update Frequency**: Adjust the sleep interval in the main loop of `entrypoint.sh`
- **Additional Logic**: Add pre/post update hooks, validation, or other custom logic

## Getting Started

1. Build the launcher container:

```bash
docker build -t yourusername/launcher .
```

2. Push the image to Docker Hub (recommended for production use):

```bash
docker push yourusername/launcher
```

3. Deploy

You can now deploy the following compose to dstack or Phala Cloud.

```yaml
services:
  launcher:
    image: yourusername/launcher
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    restart: always
```

**Note:** The example configuration above uses a placeholder `yourusername/launcher` as the image name. Make sure to update it with your actual published image name.

## License

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
