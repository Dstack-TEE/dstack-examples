# Debian trixie matches the dstack 0.6 guest OS userland.
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server openssh-sftp-server rsync \
        bash-completion ca-certificates curl dnsutils file gdb git htop \
        iproute2 iputils-ping jq less lsof procps psmisc python3 strace \
        tcpdump tmux util-linux vim \
        docker-cli docker-compose \
    && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*
COPY sshd_config /etc/ssh/sshd_config
COPY motd /etc/motd
COPY --chmod=755 host-shell /usr/local/bin/host-shell
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint"]
