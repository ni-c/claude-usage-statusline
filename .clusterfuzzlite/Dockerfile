# The image ClusterFuzzLite builds the fuzzer in. Python, because atheris is the
# engine that can drive a shell script through a subprocess; the target itself is
# statusline.sh.
#
# Digest-pinned like every other dependency here. Dependabot refreshes it: the
# docker ecosystem watches `/.clusterfuzzlite` and follows the `v1` tag.
FROM gcr.io/oss-fuzz-base/base-builder-python:v1@sha256:b02a06f9d3918428825b1ebfa2c3627b591a5924a83436b8aaec40c85fd15b16

# bash to run the script under test, git so the branch segment is fuzzed too
# rather than skipped. jq is not installed here — the fuzzer runs in a different
# image, so build.sh fetches a static one into $OUT instead.
RUN apt-get update && \
    apt-get install -y --no-install-recommends bash git && \
    rm -rf /var/lib/apt/lists/*

COPY . $SRC/claude-usage-statusline
COPY .clusterfuzzlite/build.sh $SRC/build.sh
WORKDIR $SRC/claude-usage-statusline
