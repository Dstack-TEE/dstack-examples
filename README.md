# Dstack Examples
This repository contains examples of Dstack applications.

*Note on single-file example style:* Sometimes we use a style of packing the entire application into a single docker-compose.yml file. 
But more commonly a dstack example would have Dockerfile and some other code.

## Useful Utilities
These show useful patterns you may want to copy: 
- [./lightclient](./lightclient) use a light client so that the dstack app can follow a blockchain
- [./custom-domain](./custom-domain) shows how to serve a secure website from a custom domain, by requesting a letsencrypt certificate from within the app
- [./ssh-over-tproxy](./ssh-over-tproxy) shows how to tunnel arbitrary sockets over https so it can work with tproxy
- [./webshell](./webshell) This is an alternative way to allow logging into a Dstack container (for debug only!)
## Showcases of porting existing tools
- [./tor-hidden-service](./tor-hidden-service) connects to the tor network and serves a website as a hidden service
## Illustrating Dstack Features
- [./prelaunch-script](./prelaunch-script)
- [./private-docker-image-deployment](./private-docker-image-deployment)
## App examples
- [./timelock-nts](./timelock-nts) a timelock decryption example using secure NTP (NTS) from Cloudflare as a time oracle
## Tutorial (Coming soon)

## Contributing
Pull requests are welcomed, curation plan to come soon
