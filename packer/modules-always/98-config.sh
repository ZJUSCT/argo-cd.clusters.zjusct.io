#!/usr/bin/env bash

rm -f /etc/update-motd.d/*
install -D -m 0755 /dev/stdin /etc/update-motd.d/00-nice-motd <<'EOF'
#!/bin/bash --norc
printf "\nWelcome to "; hostname
printf "  Kernel: "; uname -v
printf "  "; uptime -p
printf "\nSystem information as of "; date --rfc-3339=seconds
printf "  CPU load: "; cat /proc/loadavg | awk '{ printf "%s %s %s\n", $1, $2, $3; }'
# RAM
free -m | awk '/Mem/  { printf "  Memory:  %4sM  (%2d%%)  out of %2.1fG\n", $3, ($3/$2) * 100, $2/1000; }'
EOF
install -D -m 0644 /dev/stdin /etc/motd <<'EOF'

EOF

install -D -m 0644 /dev/stdin /etc/systemd/resolved.conf.d/disable-llmnr.conf <<EOF
[Resolve]
LLMNR=no
EOF

install -D -m 0644 /dev/stdin /etc/udev/hwdb.d/50-net-naming-denylist.hwdb <<EOF
net:naming:*:*
ID_NET_NAME_ALLOW=1
ID_NET_NAME_ALLOW_DEV_PORT=0
ID_NET_NAME_ALLOW_PHYS_PORT_NAME=0
EOF

sed -E -i 's/^#[[:space:]]*rdma=n$/rdma=y/' "/etc/nfs.conf"

install -D -m 0644 /dev/stdin /etc/sudoers.d/audit <<EOF
Defaults log_subcmds
#Defaults log_format=json
#Defaults logfile=/var/log/sudo.log
#Defaults !syslog
# https://www.sudo.ws/pipermail/sudo-users/2023-February/006538.html
Defaults !intercept_verify
EOF
