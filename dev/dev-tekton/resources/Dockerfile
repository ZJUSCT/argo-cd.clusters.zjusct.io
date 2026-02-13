FROM ubuntu

RUN sed -i 's/archive.ubuntu.com/mirrors.zju.edu.cn/g' /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update && apt-get install -y curl
