#!/bin/bash
#
# List CephFS home subvolumes sorted by size.
# Usage: ./list-home-dirs.sh [--clear-snapshots]
#
set -euo pipefail

FS="cephfs"
GROUP="home"
TOOL_POD=$(kubectl get pods -n rook-ceph -l app=rook-ceph-tools -o jsonpath='{.items[0].metadata.name}')

if [ -z "$TOOL_POD" ]; then
    echo "Error: rook-ceph-tools pod not found" >&2
    exit 1
fi

echo "Using tool pod: $TOOL_POD"

if [ "${1:-}" = "--clear-snapshots" ]; then
    echo "Clearing all snapshots under $FS/$GROUP ..."
    kubectl exec -n rook-ceph "$TOOL_POD" -- bash -c '
    ceph fs subvolume ls '"$FS"' '"$GROUP"' \
      | python3 -c "import sys,json; [print(x[\"name\"]) for x in json.load(sys.stdin)]" \
      | while read sv; do
          snaps=$(ceph fs subvolume snapshot ls '"$FS"' '"$GROUP"' "$sv" --format json 2>/dev/null)
          [ -z "$snaps" ] && continue
          echo "$snaps" \
            | python3 -c "import sys,json; [print(x[\"name\"]) for x in json.load(sys.stdin)]" \
            | while read snap; do
                echo "  Removing snapshot '$snap' from '$sv' ..."
                ceph fs subvolume snapshot rm '"$FS"' '"$GROUP"' "$sv" "$snap" --force
              done
        done
  '
    echo "All snapshots cleared."
fi

echo ""
echo "Listing subvolumes under $FS/$GROUP sorted by size:"
echo ""

kubectl exec -n rook-ceph "$TOOL_POD" -- bash -c '
  ceph fs subvolume ls '"$FS"' '"$GROUP"' \
    | python3 -c "import sys,json; [print(x[\"name\"]) for x in json.load(sys.stdin)]" \
    | while read sv; do
        bytes=$(ceph fs subvolume info '"$FS"' "$sv" '"$GROUP"' --format json 2>/dev/null \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get(\"bytes_used\",\"0\"))" 2>/dev/null)
        echo "$bytes $sv"
      done \
    | sort -rn \
    | python3 -c "
import sys
for line in sys.stdin:
    parts = line.strip().split(None, 1)
    if len(parts) != 2: continue
    b = int(parts[0])
    name = parts[1]
    for unit in [\"B\",\"KB\",\"MB\",\"GB\",\"TB\"]:
        if abs(b) < 1024:
            hsize = \"{:.1f} {}\".format(b, unit)
            break
        b /= 1024
    else:
        hsize = \"{:.1f} PB\".format(b)
    print(\"{:<30}  {:>15}\".format(name, hsize))
"
'
