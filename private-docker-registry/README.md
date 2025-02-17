# Private Docker Registry

This is a private docker registry for Dstack and Phala Cloud.

The example of [docker-compose.yml](docker-compose.yml) is provided to help you set up a private docker registry.

## Notices

- The environtment variables are required to be set in the PHALA Cloud through the `Encrypted Secrets`.

    ```
    DOCKER_USERNAME=
    DOCKER_PASSWORD=
    PRIVATE_REGISTRY_URL=
    PRIVATE_REGISTRY_USERNAME=
    PRIVATE_REGISTRY_PASSWORD=
    ```

- When the CVM is created, the `init` service will be executed to pull the images from the private registry and run the containers. All services created by the `init` service, could be accessed through the link looks like:

    ```
    https://<app-id>-<port>.dstack-prod4.phala.network/
    ```

- The `init` service will be executed only once when the CVM is created or updated, if you want to update the `docker-compose.yml`, you need to update the CVM with the updated `docker-compose.yml` file.
