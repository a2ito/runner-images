# The runner for Flutter / Android jobs: images/runner plus the Android SDK and
# Flutter. Built on top of the runner image of the same tag (make build
# passes RUNNER_IMAGE), so the runner itself is never set up twice.
#
# Why bake all this into the image instead of letting each job download it:
# Cloud Run keeps every file a job writes in memory, but the image itself does
# not count ("The size of the deployed container image does not affect memory
# that is available for the instance"). Start-up did not depend on image size
# either when measured (a few MB and 596MB both took ~1.5 minutes). So what is
# in here costs neither memory nor time per job; what a job downloads costs
# both. GitHub-hosted runners have the SDK preinstalled, and the workflows
# (apksigner under $ANDROID_HOME/build-tools) rely on that.
#
# Not baked in: the JDK and Gradle. actions/setup-java and the Gradle wrapper
# fetch their own versions each run (a few hundred MB each).
ARG RUNNER_IMAGE

FROM mcr.microsoft.com/dotnet/runtime-deps:8.0-noble AS fetch
# The defaults match the Flutter apps (hexspin, match3-flutter, ...): the SDK
# levels are Flutter's defaults for FLUTTER_VERSION (flutter.compileSdkVersion
# = 36, flutter.ndkVersion = 28.2.13676358). AGP 9.0 and 9.4 are in use, hence
# two build-tools versions. Anything missing still works -- AGP downloads it,
# since the licences are accepted -- but into memory, on every run.
#
# The Flutter hash is in releases_linux.json; Google publishes only a SHA-1 for
# cmdline-tools (repository2-3.xml), and the SHA-256 here is of the file whose
# SHA-1 matched it.
ARG FLUTTER_VERSION=3.44.8
ARG FLUTTER_SHA256=672089e001571a9fbb209a495c583580c0c6c73ef98999264ba07fa93ace332d
ARG CMDLINE_TOOLS_BUILD=16111833
ARG CMDLINE_TOOLS_SHA256=0877a1d048fe4a24efe2eff536ca4223f7adeb58648bb81909d33c446918cfa8
ARG ANDROID_PACKAGES="platform-tools platforms;android-36 build-tools;35.0.0 build-tools;36.0.0 ndk;28.2.13676358"

# sdkmanager is Java; a JRE is needed here only, not in the final image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip xz-utils git openjdk-17-jre-headless

ENV ANDROID_HOME=/opt/android-sdk
RUN curl -fsSL -o /tmp/cmdline-tools.zip \
        "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_BUILD}_latest.zip" \
    && echo "${CMDLINE_TOOLS_SHA256}  /tmp/cmdline-tools.zip" | sha256sum -c - \
    && mkdir -p "$ANDROID_HOME/cmdline-tools" \
    && unzip -q /tmp/cmdline-tools.zip -d /tmp \
    && mv /tmp/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest" \
    && yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null \
    && "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --install $ANDROID_PACKAGES

# Where subosito/flutter-action looks before downloading:
# $RUNNER_TOOL_CACHE/flutter/<channel>-<version>-<arch>/flutter. RUNNER_TOOL_CACHE
# is <runner root>/_work/_tool. When the apps move to another FLUTTER_VERSION the
# action does not find it and downloads that version -- slower, and into memory,
# but it still works. Bump FLUTTER_VERSION here with them.
ENV FLUTTER_ROOT=/home/runner/_work/_tool/flutter/stable-${FLUTTER_VERSION}-x64/flutter
RUN curl -fsSL -o /tmp/flutter.tar.xz \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    && echo "${FLUTTER_SHA256}  /tmp/flutter.tar.xz" | sha256sum -c - \
    && mkdir -p "$(dirname "$FLUTTER_ROOT")" \
    && tar -xJf /tmp/flutter.tar.xz -C "$(dirname "$FLUTTER_ROOT")" \
    && git config --global --add safe.directory "$FLUTTER_ROOT" \
    && "$FLUTTER_ROOT/bin/flutter" --disable-analytics \
    && "$FLUTTER_ROOT/bin/flutter" precache --android --no-ios --no-web --no-linux --no-windows --no-macos --no-fuchsia

FROM ${RUNNER_IMAGE}

# The workflows find the SDK through ANDROID_HOME (apksigner) and Gradle through
# ANDROID_HOME / ANDROID_SDK_ROOT, as on GitHub-hosted runners.
ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk

# Owned by the runner user: AGP writes into the SDK when it installs a missing
# package, and Flutter writes into its own directory (bin/cache, the tool's
# snapshot). Read-only, both fail.
COPY --from=fetch --chown=runner:runner /opt/android-sdk /opt/android-sdk
COPY --from=fetch --chown=runner:runner /home/runner/_work /home/runner/_work

# xz-utils lets flutter-action unpack a different Flutter version (.tar.xz)
# when the apps move ahead of the one baked in above.
#
# clang is for packages with native assets (build hooks that compile C, e.g.
# forge2d in pinball): `flutter test` builds them for the host, and without a
# compiler it fails with "No compiler configured on host 'linux_x64'".
# GitHub-hosted runners have clang preinstalled. The Android build does not
# need it -- it uses the NDK's own clang.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends xz-utils clang \
    && rm -r /var/lib/apt/lists/*
USER runner
