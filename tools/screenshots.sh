#!/bin/zsh
# Regenerate docs/images/*.png from demo data (no screen capture). Usage: tools/screenshots.sh
set -e
root=${0:A:h:h}
tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
mkdir -p $tmp/home
cp $root/tools/render-screenshots.swift $tmp/main.swift   # top-level code needs a file named main.swift
swiftc -O $root/app/Core.swift $root/app/Windows.swift $root/app/Notifier.swift \
  $tmp/main.swift -o $tmp/render 2>&1 | grep -E 'error' || true
UOS_HOME=$tmp/home UOS_DEMO_AGENT_LOADED=1 $tmp/render $root/docs/images
