#!/bin/sh

# Copyright (c) 2026 Joseph Cumines
# SPDX-License-Identifier: MIT

# setup-lima-linux-full.sh: create and provision a Lima VM named
# valise-linux-full with bash, zsh, ksh, fish, and dash available.
# The valise-sh source tree is mounted read-write by Lima's default
# home-directory mount.
#
# Usage: sh tools/setup-lima-linux-full.sh
# Requires: limactl on the host PATH.

set -eu

INSTANCE="valise-linux-full"

if ! command -v limactl >/dev/null 2>&1; then
  printf 'ERROR: limactl not found on PATH\n' >&2
  exit 1
fi

if limactl list --format '{{.Name}}' 2>/dev/null | grep -x "$INSTANCE" >/dev/null 2>&1; then
  _status=$(limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | awk -v n="$INSTANCE" '$1 == n { print $2 }')
  if [ "$_status" = "Running" ]; then
    printf 'Instance %s is already running.\n' "$INSTANCE"
    exit 0
  fi
  printf 'Instance %s exists but is %s. Starting...\n' "$INSTANCE" "$_status"
  limactl start "$INSTANCE"
  exit 0
fi

printf 'Creating Lima instance %s...\n' "$INSTANCE"

limactl start --name="$INSTANCE" --vm-type=vz --cpus=4 --memory=4 --disk=20 \
  --mount="$(pwd):$(pwd):w" \
  template://ubuntu-lts

printf 'Installing shells inside %s...\n' "$INSTANCE"

limactl shell "$INSTANCE" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get update -qq
  sudo apt-get install -y -qq bash zsh ksh fish dash coreutils
'

printf 'Verifying shell availability...\n'
for _sh in bash zsh ksh fish dash; do
  if limactl shell "$INSTANCE" command -v "$_sh" >/dev/null 2>&1; then
    printf '  OK: %s\n' "$_sh"
  else
    printf '  FAIL: %s not found\n' "$_sh" >&2
    exit 1
  fi
done

printf 'Instance %s is ready.\n' "$INSTANCE"
