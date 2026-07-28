FROM ubuntu:22.04

# Create postgres user first
RUN groupadd -r postgres --gid=999 && \
    useradd -r -g postgres --uid=999 postgres

# Install dependencies
RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get -y install tzdata
RUN apt-get install -y \
    gosu \
    python3-pip \
    postgresql-14 \
    postgresql-client-14 \
    openjdk-11-jre-headless \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install ZooKeeper
RUN curl -L https://dlcdn.apache.org/zookeeper/zookeeper-3.8.4/apache-zookeeper-3.8.4-bin.tar.gz | tar xz -C /opt \
    && mv /opt/apache-zookeeper-3.8.4-bin /opt/zookeeper

# Install Patroni
RUN pip3 install patroni[zookeeper] psycopg2-binary

# Create necessary directories with proper permissions
RUN mkdir -p /data/zookeeper /data/postgres /etc/patroni && \
    chown -R postgres:postgres /data/postgres && \
    chmod 700 /data/postgres && \
    chown -R postgres:postgres /etc/patroni

# Create necessary directories
RUN mkdir -p /data/zookeeper /data/postgres /etc/patroni

# ZooKeeper configuration
COPY zoo.cfg /opt/zookeeper/conf/

# Patroni configuration
COPY patroni.yml /etc/patroni/

# Startup script
COPY start.sh /
RUN chmod +x /start.sh

EXPOSE 2181 5432 8008

CMD ["/start.sh"]