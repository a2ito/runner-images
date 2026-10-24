#!/bin/bash
# The home PC's runner (WSL), one container per GitHub job.
#
# Each round registers a JIT runner in the organization, starts the
# runner-android image with its config and waits for the container to exit --
# after exactly one job, as on Cloud Run. The image is pulled again before every
# round, so a new :main from build.yml is picked up at the next job without
# anything pushing to this PC (it is behind NAT). A runner that is waiting for a
# job keeps the image it started with.
#
# runner-android rather than runner: the home PC takes RUNNER, RUNNER_LARGE and
# RUNNER_ANDROID alike (all three are `wsl`), and runner-android is runner plus
# the Android SDK and Flutter.
#
# The JIT config comes from the same GitHub App as the Cloud Run dispatcher
# (github-management runner/dispatcher), with its organization permission
# "Self-hosted runners: Read and write".
#
# Usage: runner-loop.sh <slot>   (systemd: wsl-runner@<slot>.service)
# Settings: /etc/wsl-runner/config (see config.example).
set -euo pipefail

SLOT=${1:?usage: runner-loop.sh <slot>}
: "${APP_ID:?APP_ID is not set (/etc/wsl-runner/config)}"
: "${PRIVATE_KEY_FILE:?PRIVATE_KEY_FILE is not set (/etc/wsl-runner/config)}"
ORG=${ORG:-a2ito}
IMAGE=${IMAGE:-ghcr.io/a2ito/runner-images/runner-android:main}
LABELS=${LABELS:-wsl}
NAME_PREFIX=${NAME_PREFIX:-winmini-wsl}
# Seconds to wait after a failed round, so a broken key or a GitHub outage does
# not turn into a tight loop of API calls.
RETRY_SECONDS=${RETRY_SECONDS:-60}

API=https://api.github.com
CONTAINER="wsl-runner-${SLOT}"
SOURCE_LABEL="org.opencontainers.image.source=https://github.com/a2ito/runner-images"

log() { echo "runner-loop[${SLOT}]: $*" >&2; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# The JWT a GitHub App signs to ask for an installation token. iat is backdated
# against clock drift and exp stays under GitHub's 10-minute ceiling, as in the
# dispatcher's appJWT.
app_jwt() {
  local now header claims signature
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  claims=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | b64url)
  signature=$(printf '%s.%s' "$header" "$claims" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" -binary | b64url)
  printf '%s.%s.%s' "$header" "$claims" "$signature"
}

# github <method> <path> <token> [body]. Prints the response body; fails on a
# non-2xx status with the body in the message.
github() {
  local method=$1 path=$2 token=$3 body=${4:-} response status
  response=$(curl -sS -w '\n%{http_code}' -X "$method" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    ${body:+-d "$body"} "${API}${path}")
  status=${response##*$'\n'}
  response=${response%$'\n'*}
  if [ "${status:0:1}" != 2 ]; then
    log "${method} ${path}: HTTP ${status}: ${response}"
    return 1
  fi
  printf '%s' "$response"
}

# round runs under `if !`, where set -e does not apply, so every step below
# checks its own status.
installation_token() {
  local jwt installation
  jwt=$(app_jwt) || { log "cannot sign the App JWT with ${PRIVATE_KEY_FILE}"; return 1; }
  installation=$(github GET "/orgs/${ORG}/installation" "$jwt" | jq -er .id) || return 1
  github POST "/app/installations/${installation}/access_tokens" "$jwt" | jq -er .token
}

# A runner registered but never started (the container failed to come up, or
# systemd stopped us first) stays in the list as offline. One that ran its job
# has already removed itself, hence the 404 is fine.
remove_runner() {
  local token=$1 id=$2
  github DELETE "/orgs/${ORG}/actions/runners/${id}" "$token" >/dev/null 2>&1 || true
}

running_id=
running_token=
stop() {
  log "stopping"
  docker stop "$CONTAINER" >/dev/null 2>&1 || true
  [ -n "$running_id" ] && remove_runner "$running_token" "$running_id"
  exit 0
}
trap stop TERM INT

round() {
  local token jit name labels

  if ! docker pull -q "$IMAGE" >/dev/null; then
    # Keep serving jobs with the image already here; only give up if there is none.
    docker image inspect "$IMAGE" >/dev/null 2>&1 || { log "cannot pull ${IMAGE}"; return 1; }
    log "cannot pull ${IMAGE}; using the local copy"
  fi
  # The previous :main, now untagged. Only this repository's images are touched.
  docker image prune -f --filter "label=${SOURCE_LABEL}" >/dev/null || true

  token=$(installation_token) || return 1
  # Unique per round so GitHub never refuses it as a duplicate.
  name="${NAME_PREFIX}-${SLOT}-$(date +%Y%m%d%H%M%S)"
  labels=$(jq -cn --arg l "$LABELS" '["self-hosted", "linux", "x64"] + ($l | split(","))')
  jit=$(github POST "/orgs/${ORG}/actions/runners/generate-jitconfig" "$token" \
    "$(jq -cn --arg name "$name" --argjson labels "$labels" \
      '{name: $name, runner_group_id: 1, labels: $labels}')") || return 1
  running_id=$(jq -er .runner.id <<<"$jit") || return 1
  running_token=$token
  log "registered ${name} (id ${running_id})"

  # JIT_CONFIG goes through the environment, not the command line, so it does
  # not show up in ps. It works once anyway.
  local status=0
  JIT_CONFIG=$(jq -r .encoded_jit_config <<<"$jit") \
    docker run --rm --name "$CONTAINER" -e JIT_CONFIG "$IMAGE" &
  wait $! || status=$?

  remove_runner "$token" "$running_id"
  running_id=
  log "${name} exited with ${status}"
  return "$status"
}

# A container left over from an unclean stop would make `docker run --name` fail.
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

while true; do
  if ! round; then
    sleep "$RETRY_SECONDS" &
    wait $!
  fi
done
