# The ephemeral runner, one container per GitHub job (a Cloud Run job execution).
#
# Built from the runner tarball rather than ghcr.io/actions/actions-runner. The
# official image is ~1.3GB unpacked, most of it things these jobs never touch:
# Docker and buildx (Cloud Run cannot run a daemon), the Kubernetes container
# hooks, a second Node.js, and the musl builds of both. Cloud Run keeps the
# container filesystem in memory, so every byte here is taken out of the job's
# memory limit -- that is what this saves. It does not make start-up faster:
# measured on 2026-10-13, a few-MB image and the official one both took about
# 1.5 minutes to reach "Started deployed execution".
#
# Versions are pinned, and the downloads checked against them, so a rebuild
# does not change behaviour on its own. When GitHub stops accepting the runner,
# it updates itself at start-up -- slow for a one-shot container, and the sign
# to bump RUNNER_VERSION. The hashes are on the release pages: the runner's in
# the release notes, gh's in gh_<version>_checksums.txt.
#
# The defaults are for Cloud Run (x86_64). To build for arm64 locally, override
# RUNNER_ARCH=arm64, GH_ARCH=arm64 and both hashes.
ARG BASE=mcr.microsoft.com/dotnet/runtime-deps:10.0-noble

FROM ${BASE} AS fetch
ARG RUNNER_VERSION=2.337.0
ARG RUNNER_ARCH=x64
ARG RUNNER_SHA256=70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613
ARG GH_VERSION=2.102.0
ARG GH_ARCH=amd64
ARG GH_SHA256=bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386
RUN apt-get update && apt-get install -y --no-install-recommends curl

WORKDIR /runner
RUN curl -fsSL -o /tmp/runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
    && echo "${RUNNER_SHA256}  /tmp/runner.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/runner.tar.gz

# Keep one Node.js, and only the binary: the runner starts JavaScript actions
# with externals/<version>/bin/node and nothing else (npm and the headers are
# never used). The *_alpine builds are musl and cannot run here anyway.
#
# node20 actions run on node24 through FORCE_JAVASCRIPT_ACTIONS_TO_NODE24 (set
# below). That alone is not enough to drop node20: the runner's own scripts --
# hashFiles() and .js hooks -- run externals/node20 by name whatever that
# variable says (NodeUtil.GetInternalNodeVersion), and would fail with "No such
# file or directory". node20 is therefore a link to node24.
RUN find externals -mindepth 1 -maxdepth 1 ! -name node24 -exec rm -r {} + \
    && find externals/node24 -mindepth 1 -maxdepth 1 ! -name bin -exec rm -r {} + \
    && find externals/node24/bin -mindepth 1 ! -name node -exec rm -r {} + \
    && ln -s node24 externals/node20

# GitHub CLI. GitHub-hosted images ship it and workflows lean on it
# (github-management's CI merges PRs with `gh pr merge`). The release binary is
# a single static file, smaller than the apt package and without its repository.
RUN curl -fsSL -o /tmp/gh.tar.gz \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${GH_ARCH}.tar.gz" \
    && echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && install -m 755 "/tmp/gh_${GH_VERSION}_linux_${GH_ARCH}/bin/gh" /usr/local/bin/gh

FROM ${BASE}

# What the jobs use beyond the runner: git for actions/checkout (without it,
# checkout falls back to the REST API and leaves no .git), unzip for
# hashicorp/setup-terraform, curl and jq for scripts. The base already has
# ca-certificates and the libraries .NET needs (ICU, OpenSSL).
RUN apt-get update \
    && apt-get install -y --no-install-recommends git curl jq unzip \
    && rm -r /var/lib/apt/lists/*

# Same user as the official image (uid 1001), so workspaces keep their owner.
RUN useradd --create-home --uid 1001 runner

COPY --from=fetch /usr/local/bin/gh /usr/local/bin/gh
COPY --from=fetch --chown=runner:runner /runner /home/runner

# Put the runner's Node.js on PATH. The runner runs JavaScript actions with it
# from /home/runner/externals, but nothing puts it on PATH -- unlike
# GitHub-hosted images, which install Node.js system-wide. Scripts that call
# `node` directly then fail with "/usr/bin/env: 'node': No such file or
# directory", the first being hashicorp/setup-terraform's wrapper, which
# replaces `terraform` with a Node.js script.
RUN ln -s /home/runner/externals/node24/bin/node /usr/local/bin/node \
    && node --version && gh --version && git --version

# The first three are what the official image sets: the runner handles SIGTERM
# itself, logs to stdout (Cloud Logging), and actions that check ImageOS see
# the same value as on ubuntu-24.04.
ENV RUNNER_MANUALLY_TRAP_SIG=1 \
    ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1 \
    ImageOS=ubuntu24 \
    FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true

USER runner
WORKDIR /home/runner

# COPY keeps the file mode from the build context (entrypoint.sh is committed as
# 755). --chmod would need BuildKit, which Cloud Build's docker builder may lack.
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
