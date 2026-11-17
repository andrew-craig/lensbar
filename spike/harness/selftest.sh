#!/bin/zsh
# Sanity check for the oracle: it must report ~25 at --fps 25 and ~30 at --fps 30.
# Run from a terminal that has camera permission.
cd "$(dirname "$0")/../.."
for f in 25 30; do
  build/spike-harness --fps $f &
  p=$!
  sleep 5
  kill -INT $p
  wait $p
done
