# FROM harbor.clusters.zjusct.io/docker.io/ubuntu/squid
#
# RUN <<EOF
# sed -i 's/[a-z]*.ubuntu.com/mirrors.zju.edu.cn/' /etc/apt/sources.list.d/ubuntu.sources
# apt-get update
# apt-get install -y squid-openssl squid-common squid-purge squidclient
# apt-get clean
# EOF

FROM harbor.clusters.zjusct.io/docker.io/ubuntu/squid AS builder

RUN <<EOF
set -xe
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
apt-get distclean
EOF

RUN <<EOF
set -xe
mkdir -p /build
cd /build
apt-get update
apt-get source squid-openssl
cd squid-6.* # TODO: this is unstable
mk-build-deps --install --remove --tool='apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends --yes'
curl -o /tmp/content-length-fix.patch https://github.com/ZJUSCT/squid/commit/a9b06626dceadbfcb0a8ce17433a018e6f5940b7.patch
export QUILT_PATCHES=debian/patches
quilt import /tmp/content-length-fix.patch
quilt push
dch --local +zjusct "Apply Content-Length preservation fix for 304 responses"
export DEB_BUILD_OPTIONS="parallel=$(nproc) nocheck nodoc noautodbgsym"
dpkg-buildpackage -us -uc -b -j$(nproc)
apt-get distclean
EOF

FROM harbor.clusters.zjusct.io/docker.io/ubuntu/squid
COPY --from=builder /build/squid-openssl*.deb /build/squid-common*.deb /build/squid-purge*.deb /build/squidclient*.deb /tmp/
RUN <<EOF
set -xe
sed -i 's/[a-z]*.ubuntu.com/mirrors.zju.edu.cn/' /etc/apt/sources.list.d/ubuntu.sources
apt-get update
apt-get install -y /tmp/squid-openssl*.deb /tmp/squid-common*.deb /tmp/squid-purge*.deb /tmp/squidclient*.deb
rm -f /tmp/squid-openssl*.deb /tmp/squid-common*.deb /tmp/squid-purge*.deb /tmp/squidclient*.deb
apt-get autoremove -y
apt-get distclean
EOF
