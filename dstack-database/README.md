# Distributed Database using Dstack

What happens if you put an ordinary replicated database in a TEE environment?
You'd expect to get a free upgrade from "omission fault tolerant" to "Byzantine fault tolerant."
Possibly we'd also benefit from blockchain observability of reconfiguration.

To start this exploration, here's a minimal fault-tolerant database service using Zookeeper+Postgres.

It's a docker-compose simulation environment for 3 nodes.
You can crash/pause any 1 of them, and the other 2 will make progress.

- `./Dockerfile` starts from ubuntu, mainly installs postgres patroni and zookeeper
- `./docker-compose.yml` defines three services
- `./patroni.yml` configures the postgres
- `./start.sh` runs zookeeper, fixes directory permissions, runs patroni
- `./zoo.cfg` zookeeper consensus

### Try it out
No configuration necessary, just run with docker compose
```bash
docker compose build
docker compose up
```
### Experiment with crashing/pausing

#### Crashing
This configuration can tolerate one node crashing.
```bash
docker compose stop dstack-database-node1-1
```
You can also rejoin a node to the network:
```bash
docker compose start dstack-database-node1-1
```

#### Pausing
You can also pause a node, causing its connections to drop. Pausing the leader takes a while to rearrange. 
```bash
docker compose pause dstack-database-node1-1
... {wait} ...
docker compose pause dstack-database-node1-1
```

#### Example logs
https://gist.github.com/amiller/c5d2c516b14760bcd4320650cb73f7e1

TODO: simulate partition
