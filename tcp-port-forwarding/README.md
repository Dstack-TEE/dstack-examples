# TCP Port Forwarding Guide

This guide outlines methods for forwarding TCP ports between your local machine and remote dstack app instances.

## A simple TCP echo server

Let's create a simple TCP echo server in python and deploy it to dstack:

```yaml
services:
  echo-server:
    image: python:3.9-slim
    command: |
      python -c "
      import socket;
      HOST = '0.0.0.0';
      PORT = 8080;
      s = socket.socket(socket.AF_INET, socket.SOCK_STREAM);
      s.bind((HOST, PORT));
      s.listen();
      while True:
        conn, addr = s.accept();
        print('Connected by', addr);
        conn.sendall(b'welcome')
        while True:
          data = conn.recv(1024);
          if not data:
            break;
          conn.sendall(data)
      "
    ports:
      - "8080:8080"
```

Run the following command to forward local port `8080` to the echo server:

```bash
socat TCP-LISTEN:8080,fork,reuseaddr OPENSSL:<app-id>-8080.<dstack-gateway-domain>:443
```

Use `nc` as client to test the echo server:

```bash
$ nc 127.0.0.1 8080
hello
hello
```
Press Ctrl+C to stop the nc client.


## SSH Access
For dstack apps using dev OS images, SSH access is available through the CVM. Connect via dstack-gateway (formerly tproxy) by:

1. Configure SSH (~/.ssh/config):
```bash
Host my-dstack-app
    HostName <your-app-id>-22.<the-dstack-gateway-domain>
    User root
    Port 443
    ProxyCommand openssl s_client -quiet -connect %h:%p
```

Change the 443 to the port of the dstack-gateway if not using the default one.

2. Connect:
```bash
ssh my-dstack-app
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
## TCP Port Forwarding Options

### Using socat (Unix-like systems)

Let's set some variables for convenience.
```bash
APP_ID=<your-app-id>
DSTACK_GATEWAY_DOMAIN=<the-dstack-gateway-domain>
GATEWAY_PORT=<the-dstack-gateway-port>
```

On Unix-like systems, we can use `socat` to forward ports.

Assuming we have a nginx server listening on port `80` in the dstack app, we can access it via the dstack-gateway `HTTPS` endpoint.
```
curl https://<app-id>.<dstack-gateway-domain>
```

If our client doesn't support `HTTPS`, we can use `socat` to forward port `80` to the local machine.

```bash
socat TCP-LISTEN:1080,bind=127.0.0.1,fork,reuseaddr OPENSSL:${APP_ID}-80.${DSTACK_GATEWAY_DOMAIN}:${GATEWAY_PORT}
```

Then we can access the nginx server over plain HTTP via the local port `1080`.

```bash
curl http://127.0.0.1:1080
```

Similarly, we can forward port `22` to the local machine.

```bash
socat TCP-LISTEN:1022,bind=127.0.0.1,fork,reuseaddr OPENSSL:${APP_ID}-22.${DSTACK_GATEWAY_DOMAIN}:${GATEWAY_PORT}
```

Then we can access the SSH server via the local port `1022`.

```bash
ssh root@127.0.0.1 -p 1022
```

### Using python script

If socat is unavailable, particularly on Windows systems, we can utilize a Python script for port forwarding.

```bash
python3 port_forwarder.py -l 127.0.0.1:1080 -r ${APP_ID}-80.${DSTACK_GATEWAY_DOMAIN}:${GATEWAY_PORT}
```

Subsequently, we can connect to the Nginx server through plain HTTP using local port `1080`.

```bash
curl http://127.0.0.1:1080
```
