#!/usr/bin/env bash
# ai-gate/set-secret.sh
# Set ANTHROPIC_API_KEY on all repos that use ci-workflows.
# Usage: bash ai-gate/set-secret.sh [secret-value]
#   If secret-value is omitted, prompts securely.

set -euo pipefail

REPOS=(
  api-gateway
  blackbook
  clodapp
  cluster-ops-agent
  gol
  home
  javaman
  javaman-client
  k8s-dashboard
  naivefront
  portfolio
  portfolio-api
  priorauth-assist
  receipts
  simcity-lite
  ci-workflows
)

if [[ $# -ge 1 ]]; then
  KEY="$1"
else
  read -r -s -p "ANTHROPIC_API_KEY: " KEY
  echo
fi

if [[ -z "$KEY" ]]; then
  echo "Error: key is empty." >&2
  exit 1
fi

for repo in "${REPOS[@]}"; do
  echo "$KEY" | gh secret set ANTHROPIC_API_KEY --repo "rkamradt/$repo"
  echo "  set: rkamradt/$repo"
done

echo "Done."
