#!/usr/bin/env bash
# Build the fuzzer ClusterFuzzLite runs. Called inside the image built from the
# Dockerfile next door, with $SRC and $OUT set by the base image.
set -eu

cd "$SRC/claude-usage-statusline"

# The target. compile_python_fuzzer bundles the harness into a self-contained
# binary, so nothing of this checkout survives into the run — hence the copies below.
compile_python_fuzzer fuzz/fuzz_statusline.py

# libFuzzer grows its input length only when coverage grows, and coverage cannot
# grow here: the code under test is a shell script, so there is nothing for it to
# instrument. Left alone it spends the whole run on six-byte inputs, which reach
# none of the fields. len_control=0 hands the generator a full-length draw from
# the first execution.
cat >"$OUT/fuzz_statusline.options" <<'OPTIONS'
[libfuzzer]
max_len = 4096
len_control = 0
OPTIONS

# The script under test, next to the fuzzer: the harness looks for it there first.
cp statusline.sh "$OUT/statusline.sh"

# A static jq, because the image the fuzzer runs in has none and statusline.sh
# exits early without it — the run would prove nothing. Pinned by checksum: every
# GitHub Action around this is SHA-pinned, and piping an unverified binary from
# the network into the same build would defeat that.
JQ_VERSION=1.8.2
JQ_SHA256=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f
curl -fsSL --proto '=https' --tlsv1.2 -o "$OUT/jq" \
  "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64"
echo "${JQ_SHA256}  $OUT/jq" | sha256sum -c -
chmod +x "$OUT/jq"
