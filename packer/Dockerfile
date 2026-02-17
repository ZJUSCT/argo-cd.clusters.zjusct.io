FROM harbor.clusters.zjusct.io/docker.io/hashicorp/packer:latest

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.zju.edu.cn/g' /etc/apk/repositories
RUN <<EOF
apk del xorriso # conflict with cloud-utils-localds
apk add --no-cache \
    qemu-system-x86_64 \
    qemu-img \
    ovmf \
    curl \
    bash \
    cloud-utils-localds
EOF
