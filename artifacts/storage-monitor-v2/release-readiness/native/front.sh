#!/bin/sh
# Prints the frontmost app's bundle identifier; exits 1 unless it equals $1.
id=$(lsappinfo info -only bundleid "$(lsappinfo front)" | sed -n 's/.*"CFBundleIdentifier"="\([^"]*\)".*/\1/p; s/.*bundleID="\([^"]*\)".*/\1/p' | head -1)
echo "front=$id"; [ "$id" = "$1" ]
