# Minecraft in Dstack

Existing Minecraft docker compose files work out of the box! 
https://github.com/itzg/docker-minecraft-server/

There are a few ways of connecting.

Some slides on my minecraft notes so far: https://docs.google.com/presentation/d/1vFqlFeFFaEPlboymo_-EjASeu3kgKuXnmPc63abWcps/edit

## For unmodified clients (server needs free ngrok api)


To join my minecraft server w/ direct connection (via ngrok):
```
0.tcp.us-cal-1.ngrok.io:19314
```

Docker compose w/ Ngrok (works w unmodified minecraft client):
- https://github.com/itzg/docker-minecraft-server/blob/master/examples/docker-compose-ngrok.yml


## For client that is willing to run stunnel or socat

Bare Minecraft docker compose (works if you use stunnel or socat on client):
- https://github.com/itzg/docker-minecraft-server/blob/master/examples/docker-compose.yml

With socat:
```
socat TCP-LISTEN:25565,bind=127.0.0.1,fork,reuseaddr OPENSSL:fd2cd876576b10d9f31924e8cb1604f1ad4e8f03-25565.dstack-prod5.phala.network:443
```

## To make a fully secure connection (for T-E-Esports)

First to get a reference certificate:
```
openssl s_client -connect fd2cd876576b10d9f31924e8cb1604f1ad4e8f03-25565.dstack-prod5.phala.network:443 </dev/null | sed -n '/-----BEGIN/,/-----END/p' > pinned.crt 
```

then use a tunneling tool (stunnel) that can check against this reference:

```
stunnel ./stunnel.conf
```

Example `stunnel.conf`:
```
foreground = yes
pid = ./stunnel.pid

[minecraft]
client = yes
accept = 127.0.0.1:25565
connect = fd2cd876576b10d9f31924e8cb1604f1ad4e8f03-25565.dstack-prod5.phala.network:443
verifyPeer = yes
CAfile = pinned.crt
checkHost = fd2cd876576b10d9f31924e8cb1604f1ad4e8f03-25565.dstack-prod5.phala.network
```
