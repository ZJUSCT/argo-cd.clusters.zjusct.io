FROM harbor.clusters.zjusct.io/docker.io/ubuntu/squid

RUN <<EOF
sed -i 's/[a-z]*.ubuntu.com/mirrors.zju.edu.cn/' /etc/apt/sources.list.d/ubuntu.sources
sed -i 's/Types: deb/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    devscripts \
    equivs \
    git \
    ca-certificates \
    quilt \
    curl
EOF

RUN <<EOF
mkdir -p /build
cd /build
apt-get source squid-openssl
cd squid-6.*
mk-build-deps --install --remove --tool='apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends --yes'
curl -o /tmp/content-length-fix.patch https://github.com/ZJUSCT/squid/commit/0ccbcbc.patch
export QUILT_PATCHES=debian/patches
quilt import /tmp/content-length-fix.patch
quilt push
dch --local +zjusct "Apply Content-Length preservation fix for 304 responses"
dpkg-buildpackage -us -uc -b -j
apt-get install -y ../squid-openssl*.deb ../squid-common*.deb ../squid-purge*.deb ../squidclient*.deb
apt-get clean
EOF

ENV TZ="Asia/Shanghai"
