#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
cd "$project_dir"

if rg -n --hidden --glob '!/.build/**' --glob '!/dist/**' --glob '!/.git/**' --glob '!Scripts/audit-public-release.sh' \
  '(gh[pousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+|AKIA[0-9A-Z]{16}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|/Users/[^/[:space:]]+|HVWR|33044CB7)' .; then
  print -u2 'Public-release audit failed: a possible secret or local identifier was found.'
  exit 1
fi

if rg -n --hidden --glob '!/.build/**' --glob '!/dist/**' --glob '!/.git/**' --glob '!Scripts/audit-public-release.sh' \
  'xattr -[cr]|sudo |curl .*[|].*bash|rm -rf|disable-library-validation' .; then
  print -u2 'Public-release audit failed: a disallowed installation or privacy pattern was found.'
  exit 1
fi

print 'Public-release audit passed.'
