# SSH Over Gateway Example

This guide illustrates how to set up an SSH server within a tapp and access it using a public dstack-gateway endpoint.

## Installation Steps

1. **Deploy the Docker Compose File**  
   Start by deploying the provided `docker-compose.yaml` on Dstack or Phala Cloud. Adjust the workload section as needed, and remember to set the root password using the `ROOT_PW` environment variable.

2. **Configure Your SSH Client**
   Add the following configuration block to your `~/.ssh/config` file:
   ```
   Host my-tee-box
       ProxyCommand openssl s_client -quiet -connect <app-id>-1022.<dstack-serv-domain>:443
   ```
   Be sure to replace `<app-id>` with your tapp's application ID and `<dstack-serv-domain>` with your dstack-gateway server's domain.
   Change the 443 to the port of the dstack-gateway if not using the default one.
   Example ProxyCommand: `ProxyCommand openssl s_client -quiet -connect c3c0ed2429a72e11e07c8d5701725968ff234dc0-1022.dstack-prod5.phala.network:443`

3. **Connect via SSH command**
   Finally, initiate the connection by running:
   ```
   ssh root@my-tee-box
   ```

> [!WARNING]  
> macOS users may encounter connection timeout problem when connecting to the tls endpoint. That's
> because the `openssl` shipped with the OS is LibraSSL and the syntax is slightly different. You
> can confirm your `openssl` version by `openssl version`.
>
> There's a simple fix. Install [homebrew](https://brew.sh/) and install OpenSSL:
>
> `brew install openssl`
>
> Then the connection should be good.