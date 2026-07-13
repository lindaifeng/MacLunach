#!/bin/zsh
set -euo pipefail

expected="14.0"
files=(Config/Base.xcconfig Packages/TouchKit/Package.swift project.yml)

for file in $files; do
  [[ -f "$file" ]] || { print -u2 "missing deployment source: $file"; exit 1; }
done

rg -q "MACOSX_DEPLOYMENT_TARGET = $expected" Config/Base.xcconfig
rg -q "\\.macOS\\(\\.v14\\)" Packages/TouchKit/Package.swift
rg -q "macOS: '$expected'" project.yml
rg -U -q "ScreenshotService:\n[[:space:]]+type: xpc-service\n[[:space:]]+platform: macOS\n[[:space:]]+deploymentTarget: '$expected'" project.yml
rg -q "PRODUCT_BUNDLE_IDENTIFIER: me.touch.launcher.ScreenshotService" project.yml

bad_targets=$(rg -n "deploymentTarget: '[^']+'" project.yml | rg -v "'$expected'" || true)
if [[ -n "$bad_targets" ]]; then
  print -u2 "$bad_targets"
  print -u2 "inconsistent deployment target"
  exit 1
fi

print "deployment targets are consistent at macOS $expected"
