#!/bin/bash
# The home PC's runner (WSL): runs exactly one GitHub job in a fresh container
# and exits. systemd (wsl-runner@.service, Restart=always) starts it again, so
# there is no loop here.
#
# Each run pulls the image, registers a JIT runner in the organization and
# starts the runner-android image with its config -- the same as one Cloud Run
# execution. Because every run pulls first, a new :main from build.yml is
# picked up at the next start without anything pushing to this PC (it is behind
# NAT). A runner that is waiting for a job keeps the image it started with.
#
# runner-android rather than runner: the home PC takes RUNNER, RUNNER_LARGE and
# RUNNER_ANDROID alike (all three are `wsl`), and runner-android is runner plus
# the Android SDK and Flutter.
#
# The JIT config comes from the same GitHub App as the Cloud Run dispatcher
# (github-management runner/dispatcher), with its organization permission
# "Self-hosted runners: Read and write".
#
# Usage: run-once.sh <slot>   (systemd: wsl-runner@<slot>.service)
# Settings: /etc/wsl-runner/config (see config.example).
set -euo pipefail

SLOT=${1:?usage: run-once.sh <slot>}
: "${APP_ID:?APP_ID is not set (/etc/wsl-runner/config)}"
: "${PRIVATE_KEY_FILE:?PRIVATE_KEY_FILE is not set (/etc/wsl-runner/config)}"
ORG=${ORG:-a2ito}
IMAGE=${IMAGE:-ghcr.io/a2ito/runner-images/runner-android:main}
LABELS=${LABELS:-wsl}
NAME_PREFIX=${NAME_PREFIX:-winmini-wsl}

API=https://api.github.com
CONTAINER="wsl-runner-${SLOT}"
SOURCE_LABEL="org.opencontainers.image.source=https://github.com/a2ito/runner-images"

log() { echo "run-once[${SLOT}]: $*" >&2; }

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

installation_token() {
  local jwt installation
  jwt=$(app_jwt)
  installation=$(github GET "/orgs/${ORG}/installation" "$jwt" | jq -er .id)
  github POST "/app/installations/${installation}/access_tokens" "$jwt" | jq -er .token
}

# Checked before the pull: the first pull of runner-android takes minutes, and a
# missing key would otherwise only show up after it, as an openssl error.
if [ ! -r "$PRIVATE_KEY_FILE" ]; then
  log "cannot read the App private key ${PRIVATE_KEY_FILE} (see wsl/README.md)"
  exit 1
fi

# A container left over from an unclean stop would make `docker run --name` fail.
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

log "pulling ${IMAGE}"
if ! docker pull -q "$IMAGE" >/dev/null; then
  # Keep serving jobs with the image already here; only give up if there is none.
  docker image inspect "$IMAGE" >/dev/null 2>&1 || { log "cannot pull ${IMAGE}"; exit 1; }
  log "cannot pull ${IMAGE}; using the local copy"
fi
# The previous :main, now untagged. Only this repository's images are touched.
docker image prune -f --filter "label=${SOURCE_LABEL}" >/dev/null || true

token=$(installation_token)
# Unique per run so GitHub never refuses it as a duplicate.
name="${NAME_PREFIX}-${SLOT}-$(date +%Y%m%d%H%M%S)"
labels=$(jq -cn --arg l "$LABELS" '["self-hosted", "linux", "x64"] + ($l | split(","))')
jit=$(github POST "/orgs/${ORG}/actions/runners/generate-jitconfig" "$token" \
  "$(jq -cn --arg name "$name" --argjson labels "$labels" \
    '{name: $name, runner_group_id: 1, labels: $labels}')")
runner_id=$(jq -er .runner.id <<<"$jit")
log "registered ${name} (id ${runner_id})"

# A runner registered but never started (the container failed to come up, or
# systemd stopped us first) stays in the list as offline. One that ran its job
# has already removed itself, hence the 404 is fine. The token lasts an hour, so
# after a long job this may fail too -- also fine, for the same reason.
cleanup() {
  docker stop "$CONTAINER" >/dev/null 2>&1 || true
  github DELETE "/orgs/${ORG}/actions/runners/${runner_id}" "$token" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# JIT_CONFIG goes through the environment, not the command line, so it does not
# show up in ps. It works once anyway. Run in the background and wait, so that
# systemd's SIGTERM reaches the trap without waiting for the job to finish.
JIT_CONFIG=$(jq -r .encoded_jit_config <<<"$jit") \
  docker run --rm --name "$CONTAINER" -e JIT_CONFIG "$IMAGE" &
wait $!
