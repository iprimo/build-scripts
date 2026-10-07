#!/usr/bin/env bash
#
# bootstrap.sh — tiny loader you keep locally (or run via curl).
# Pulls the latest ubuntu-server-setup.sh from GitHub and runs it,
# so the interactive menu gets a real terminal instead of a pipe.
#
set -euo pipefail

REPO="iprimo/build-scripts"
BRANCH="main"
SCRIPT="ubuntu-server-setup.sh"
URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${SCRIPT}"

TMP="$(mktemp /tmp/${SCRIPT}.XXXXXX)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

echo "Fetching latest ${SCRIPT} from ${REPO}@${BRANCH}..."
curl -fsSL "$URL" -o "$TMP"
chmod +x "$TMP"

exec sudo bash "$TMP"
