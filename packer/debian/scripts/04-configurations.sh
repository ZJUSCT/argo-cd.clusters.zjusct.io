#!/usr/bin/env bash
set -xeou pipefail

########################################################################
# NFS over RDMA
########################################################################
sed -E -i 's/^#[[:space:]]*rdma=n$/rdma=y/' "/etc/nfs.conf"

########################################################################
# NVIDIA Performance Metrics
########################################################################
cat >/etc/modprobe.d/nvidia-perf.conf <<EOF
options nvidia NVreg_RestrictProfilingToAdminUsers=0
EOF

########################################################################
# MOTD
# https://github.com/Gaeldrin/nice-motd
########################################################################

rm -f /etc/update-motd.d/*
cat >/etc/update-motd.d/00-nice-motd <<'EOF'
#!/bin/bash --norc
printf "\nWelcome to "; hostname
# printf "  Kernel: "; uname -v
printf "  "; uptime -p
printf "\nSystem information as of "; date --rfc-3339=seconds
printf "  CPU load: "; cat /proc/loadavg | awk '{ printf "%s %s %s\n", $1, $2, $3; }'
# RAM
free -m | awk '/Mem/  { printf "  Memory:  %4sM  (%2d%%)  out of %2.1fG\n", $3, ($3/$2) * 100, $2/1000; }'
EOF

chmod +x /etc/update-motd.d/00-nice-motd

cat >/etc/motd <<EOF
EOF
