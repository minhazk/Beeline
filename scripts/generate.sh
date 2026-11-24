#!/bin/sh
# Regenerates Beeline.xcodeproj from project.yml (the project file isn't committed).
set -e
cd "$(dirname "$0")/.."
[ -f Config/Secrets.xcconfig ] || cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
xcodegen generate
