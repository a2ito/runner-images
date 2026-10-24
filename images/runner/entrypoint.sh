#!/bin/bash
# Runs exactly one GitHub job and exits. The dispatcher sets JIT_CONFIG when it
# starts the execution; the job definition in cloud-management leaves it empty.
set -euo pipefail

if [ -z "${JIT_CONFIG:-}" ]; then
  # Started by hand, or by a retry: the JIT config is single-use, so there is
  # nothing useful to do. Fail loudly instead of waiting for a job forever.
  echo "entrypoint: JIT_CONFIG is empty -- this container must be started by the dispatcher" >&2
  exit 1
fi

cd /home/runner
exec ./run.sh --jitconfig "$JIT_CONFIG"
