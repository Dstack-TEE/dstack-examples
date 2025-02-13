# SSH Over TPROXY Example

This guide illustrates how to set up an SSH server within a tapp and access it using a public tproxy endpoint.

## Installation Steps

1. **Deploy the Docker Compose File**  
   Start by deploying the provided `docker-compose.yaml` on Dstack or Phala Cloud. Adjust the workload section as needed, and remember to set the root password using the `ROOT_PW` environment variable.

2. **Install `httpsconnect`**  
   Ensure that the `httpsconnect` executable is in your system's `PATH`. For instance, you can run:
   ```
   chmod +x httpsconnect && sudo cp httpsconnect /usr/local/bin/
   ```

3. **Configure Your SSH Client**  
   Add the following configuration block to your `~/.ssh/config` file:
   ```
   Host my-tapp
       HostName localhost
       Port 1022
       ProxyCommand httpsconnect --proxy <app-id>-8080.<tproxy-serv-domain> -u user -p pass %h %p
   ```
   Be sure to replace `<app-id>` with your tapp's application ID and `<tproxy-serv-domain>` with your tproxy server's domain.

4. **Connect via SSH command**  
   Finally, initiate the connection by running:
   ```
   ssh root@my-tapp
   ```
