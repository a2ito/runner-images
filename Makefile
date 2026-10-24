# Build the runner images with Cloud Build and point the runner jobs at them.
#
# The Cloud Run jobs, the image repository and the service accounts are created
# by the cloud-management repository (modules/gcp/github_runner_dispatcher),
# with placeholder images. These targets only build our images and swap them
# in; Terraform there ignores the image field, so the two never fight. The
# dispatcher service is built and deployed from github-management.

# Local settings -- GCLOUD_ACCOUNT at least. The file is git-ignored and
# optional: the same variables can come from the environment instead.
-include .env

PROJECT ?= a2ito-github-runner
REGION  ?= us-central1
REPO    ?= $(REGION)-docker.pkg.dev/$(PROJECT)/gh-runner
BUILDER ?= projects/$(PROJECT)/serviceAccounts/gh-runner-builder@$(PROJECT).iam.gserviceaccount.com
# Created by cloud-management. Without it gcloud makes <project>_cloudbuild on
# its own, which the builder account has no access to -- the build then fails
# with "does not have storage.objects.get access".
SOURCE  ?= gs://$(PROJECT)-gh-runner-source/source
# The account gcloud runs as. No default: this repository is public, and the
# address is personal. Pass it from the environment or .env.
GCLOUD_ACCOUNT ?=
# One Cloud Run job per runner size (cloud-management: runner_sizes). A size
# added there needs its job name added to one of these lists, or it keeps the
# placeholder image it was created with. The jobs in JOBS run images/runner;
# those in ANDROID_JOBS run images/runner-android.
JOBS         ?= gh-runner-runner gh-runner-runner-large
ANDROID_JOBS ?= gh-runner-runner-android

# Tag images with the commit so a deployed image can be traced to its source.
# A dirty tree gets a suffix: that image cannot be rebuilt from the commit.
TAG ?= $(shell git rev-parse --short HEAD)$(shell git diff --quiet -- images cloudbuild.yaml || echo -dirty)

GCLOUD = gcloud --project=$(PROJECT) --account=$(GCLOUD_ACCOUNT)

# The builder account only has artifactregistry.writer on the one repository
# -- the default Cloud Build account can do far more. Running as it requires a
# logging option, which only a config file can set (cloudbuild.yaml).
BUILD = $(GCLOUD) builds submit --config=cloudbuild.yaml \
	--service-account=$(BUILDER) --gcs-source-staging-dir=$(SOURCE)

.PHONY: help build deploy check-account

help:
	@echo 'build  - build the runner images with Cloud Build (TAG=<git sha>)'
	@echo 'deploy - point the runner jobs at TAG'
	@echo
	@echo 'Both need GCLOUD_ACCOUNT, from the environment or .env.'

check-account:
ifeq ($(strip $(GCLOUD_ACCOUNT)),)
	$(error GCLOUD_ACCOUNT is empty -- e.g. GCLOUD_ACCOUNT=you@example.com make build)
endif

# images/runner-android starts FROM the runner image of the same tag, so the
# runner image has to be pushed first.
build: check-account
	$(BUILD) images/runner --substitutions=_IMAGE=$(REPO)/runner:$(TAG)
	$(BUILD) images/runner-android \
		--substitutions=_IMAGE=$(REPO)/runner-android:$(TAG),_RUNNER_IMAGE=$(REPO)/runner:$(TAG)

# Only the image changes: environment, service account and resources come from
# Terraform in cloud-management and are left as they are.
deploy: check-account
	for job in $(JOBS); do \
		$(GCLOUD) run jobs update $$job --region=$(REGION) \
			--image=$(REPO)/runner:$(TAG) || exit 1; \
	done
	for job in $(ANDROID_JOBS); do \
		$(GCLOUD) run jobs update $$job --region=$(REGION) \
			--image=$(REPO)/runner-android:$(TAG) || exit 1; \
	done
