# The image ClusterFuzzLite builds the fuzzer in. Python, because atheris is the
# engine that can drive a shell script through a subprocess; the target itself is
# statusline.sh.
#
# Digest-pinned like every other dependency here. Dependabot refreshes it: the
# docker ecosystem watches `/.clusterfuzzlite` and follows the `v1` tag.
FROM gcr.io/oss-fuzz-base/base-builder-python:v1@sha256:140e90791e768fdcbbbd9f7299e5d4d9fc8cfd1ed3c906aa1ca555c9dfe69fa6

# bash to run the script under test, git so the branch segment is fuzzed too
# rather than skipped. jq is not installed here — the fuzzer runs in a different
# image, so build.sh fetches a static one into $OUT instead.
RUN apt-get update && \
    apt-get install -y --no-install-recommends bash git && \
    rm -rf /var/lib/apt/lists/*

COPY . $SRC/claude-usage-statusline
COPY .clusterfuzzlite/build.sh $SRC/build.sh
WORKDIR $SRC/claude-usage-statusline
