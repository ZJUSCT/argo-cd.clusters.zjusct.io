#!/usr/bin/env bash
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

find production dev -type f \( -name "*.yaml" -o -name "*.yml" \) | while read file; do
  [[ "$file" == *"charts/"* ]] && continue

  kind=$(yq '.kind' "$file" 2>/dev/null || echo "")
  if [ "$kind" = "Secret" ]; then
    echo "️[WARN] Plaintext secret in: $file"
  fi
done

exit 0
