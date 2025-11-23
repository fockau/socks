FROM debian:bookworm-slim

RUN apt-get update -y && apt-get install -y \
    openvpn \
    curl \
    jq \
    procps \
    dante-server \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/openvpn/client /var/log && \
    rm -f /var/log/openvpn.log /var/log/openvpnsb.log && \
    touch /var/log/openvpn.log /var/log/openvpnsb.log && \
    chmod 644 /var/log/openvpn.log /var/log/openvpnsb.log

COPY danted.conf /etc/danted.conf
COPY auto-reload.sh /usr/local/bin/auto-reload.sh

RUN chmod +x /usr/local/bin/auto-reload.sh

ENV LOG_FILE=/var/log/openvpn.log \
    FAIL_COUNT_FILE=/var/log/openvpnsb.log

EXPOSE 1080

CMD ["/usr/local/bin/auto-reload.sh"]
