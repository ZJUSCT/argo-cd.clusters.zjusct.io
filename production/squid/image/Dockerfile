FROM harbor.clusters.zjusct.io/docker.io/ubuntu/squid

RUN <<EOF
sed -i 's/[a-z]*.ubuntu.com/mirrors.zju.edu.cn/' /etc/apt/sources.list.d/ubuntu.sources
apt-get update
apt-get install -y squid-openssl squid-common squid-purge squidclient
apt-get clean
EOF
