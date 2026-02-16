FROM harbor.clusters.zjusct.io/docker.io/hashicorp/packer:latest

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.zju.edu.cn/g' /etc/apk/repositories
RUN apk add --no-cache \
    qemu-system-x86_64 \
    qemu-img \
    qemu-ui-gtk \
    ovmf \
    curl \
    bash
