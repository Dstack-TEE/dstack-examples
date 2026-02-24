#!/bin/bash
set -e

# Fix permissions on runtime
mkdir -p /var/run/postgresql
chown postgres:postgres /var/run/postgresql
chmod 2777 /var/run/postgresql

# Start ZooKeeper
echo ${NODE_NAME} | sed 's/^node//' > /data/zookeeper/myid
/opt/zookeeper/bin/zkServer.sh start

# Replace template variables
sed -i "s/#{NODE_NAME}/$NODE_NAME/g" /etc/patroni/patroni.yml
sed -i "s/#{NODE_IP}/$NODE_IP/g" /etc/patroni/patroni.yml

# Start Patroni as postgres user
exec gosu postgres patroni /etc/patroni/patroni.yml

# Start Patroni
exec patroni /etc/patroni/patroni.yml
