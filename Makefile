# Point the runner jobs at an image that GitHub Actions pushed to ghcr.io.
#
# The images are built and pushed by .github/workflows/build.yml on every push
# to main, tagged with the full commit SHA. Cloud Run pulls public ghcr.io
# images directly, so no Artifact Registry repository is involved.
#
# The Cloud Run jobs and their service accounts are created by the
# cloud-management repository (modules/gcp/github_runner_dispatcher), with
# placeholder images. Terraform there ignores the image field, so this and that
# never fight. The dispatcher service is built and deployed from
# github-management.

# Local settings -- GCLOUD_ACCOUNT at least. The file is git-ignored and
# optional: the same variables can come from the environment instead.
-include .env

PROJECT ?= a2ito-github-runner
REGION  ?= us-central1
REPO    ?= ghcr.io/a2ito/runner-images
# The account gcloud runs as. No default: this repository is public, and the
# address is personal. Pass it from the environment or .env.
GCLOUD_ACCOUNT ?=
# One Cloud Run job per runner size (cloud-management: runner_sizes). A size
# added there needs its job name added to one of these lists, or it keeps the
# placeholder image it was created with. The jobs in JOBS run images/runner;
# those in ANDROID_JOBS run images/runner-android.
JOBS         ?= gh-runner-runner gh-runner-runner-large
ANDROID_JOBS ?= gh-runner-runner-android

# The commit whose images to deploy -- the full SHA, as build.yml tags them.
# Defaults to the local HEAD, which has to be on main and pushed: images exist
# only for commits that build.yml has run on.
TAG ?= $(shell git rev-parse HEAD)

GCLOUD = gcloud --project=$(PROJECT) --account=$(GCLOUD_ACCOUNT)

.PHONY: help deploy check-account

help:
	@echo 'deploy - point the runner jobs at the images of TAG (default: HEAD)'
	@echo
	@echo 'Needs GCLOUD_ACCOUNT, from the environment or .env.'

check-account:
ifeq ($(strip $(GCLOUD_ACCOUNT)),)
	$(error GCLOUD_ACCOUNT is empty -- e.g. GCLOUD_ACCOUNT=you@example.com make deploy)
endif

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
