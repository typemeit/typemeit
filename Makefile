# The speech model. The app itself builds with xcodegen and xcodebuild -- see
# CLAUDE.md -- and nothing here touches it.
#
#   make model              convert and quantise the GGUF the app downloads
#   make model-sums         print the ModelStore.swift constants for it
#   make model-verify       check the built GGUF against what ModelStore.swift pins
#   make model-publish      attach that GGUF to a GitHub release and print its URL
#   make model-verify-url   re-download the published asset and hash it
#   make eval               score the clean-up prompt on Apple Intelligence
#   make bench MODELS=...   score the same cases on local GGUF models
#   make globe-key-image    rebuild the onboarding 🌐 key image from design/onboarding
#   make diarizer-model     fetch the speaker model files FluidAudio pins and tar them
#   make diarizer-model-sums    print the DiarizerModelStore.swift constants for the tar
#   make diarizer-model-verify  check the tar against what DiarizerModelStore.swift pins
#   make diarizer-model-publish attach the tar to a GitHub release and print its URL
#   make diarizer-model-verify-url  re-download the published tar and hash it

MODEL ?= nvidia/parakeet-unified-en-0.6b
QUANT ?= Q8_0

SLUG := $(notdir $(MODEL))
GGUF := build/parakeet-convert/models/$(SLUG)/$(SLUG)-$(QUANT).gguf

# The release tag deliberately does not start with `v`: .github/workflows/release.yml
# builds and notarises on `v*`, and a model upload is not an app release.
TAG ?= model-$(SLUG)-$(shell echo $(QUANT) | tr '[:upper:]' '[:lower:]')

TRANSCRIBE := $(shell sed -n 's|.*releases/download/\(v[^/]*\)/.*|\1|p' Packages/TranscribeCpp/Package.swift)

# What the shipped app will accept. It hashes the file after downloading and
# throws away anything that does not match, so publishing a file that disagrees
# with these is publishing a download that can only fail.
STORE := TypeMeIt/ModelStore.swift
PINNED_SHA := $(shell sed -n 's/.*let sha256 = "\([0-9a-f]*\)".*/\1/p' $(STORE))
PINNED_BYTES := $(shell sed -n 's/.*let expectedBytes: Int64 = \([0-9_]*\).*/\1/p' $(STORE) | tr -d _)

# The speaker model (docs/meetings.md 8.2): the offline diarizer's files at
# the Hugging Face revision FluidAudio pins (Sources/FluidAudio/ModelNames.swift,
# Repo.diarizer.revision), mirrored to a release so the app never fetches from
# Hugging Face and gets exactly the files that were tested.
DIARIZER_REVISION ?= df2625ac79a7ac6b65ad868fee6d80f320da4232
DIARIZER_TAR := build/diarizer/speaker-diarization-$(shell echo $(DIARIZER_REVISION) | cut -c1-8).tar
DIARIZER_TAG ?= model-fluidaudio-diarizer-$(shell echo $(DIARIZER_REVISION) | cut -c1-8)
DIARIZER_STORE := TypeMeIt/Meetings/DiarizerModelStore.swift
DIARIZER_PINNED_SHA := $(shell sed -n 's/.*let sha256 = "\([0-9a-f]*\)".*/\1/p' $(DIARIZER_STORE))
DIARIZER_PINNED_BYTES := $(shell sed -n 's/.*let expectedBytes: Int64 = \([0-9_]*\).*/\1/p' $(DIARIZER_STORE) | tr -d _)

.DEFAULT_GOAL := help
.PHONY: help model model-sums model-verify model-publish model-verify-url eval bench \
	diarizer-model diarizer-model-sums diarizer-model-verify diarizer-model-publish diarizer-model-verify-url

help:
	@sed -n 's/^#   //p' Makefile

# A file target, so a second run does not redo several GB of work.
$(GGUF):
	Scripts/convert-parakeet-gguf.sh $(MODEL) $(QUANT)

model: $(GGUF)

model-sums: $(GGUF)
	@echo '    nonisolated static let fileName = "$(notdir $(GGUF))"'
	@echo '    nonisolated static let expectedBytes: Int64 = '$$(wc -c < $(GGUF) | tr -d ' ')
	@echo '    nonisolated static let sha256 = "'$$(shasum -a 256 $(GGUF) | cut -d' ' -f1)'"'

model-verify: $(GGUF)
	@sha=$$(shasum -a 256 $(GGUF) | cut -d' ' -f1); \
	bytes=$$(wc -c < $(GGUF) | tr -d ' '); \
	if [ "$$sha" != "$(PINNED_SHA)" ] || [ "$$bytes" != "$(PINNED_BYTES)" ]; then \
		echo "$(GGUF) is not the file $(STORE) pins."; \
		echo "  built  $$sha  $$bytes bytes"; \
		echo "  pinned $(PINNED_SHA)  $(PINNED_BYTES) bytes"; \
		echo "Run 'make model-sums' and update $(STORE) before publishing."; \
		exit 1; \
	fi; \
	echo "$$sha matches $(STORE)"

# Verified first: uploading a file the app will reject wastes the upload and
# leaves a release that cannot be installed. --latest=false because Sparkle's
# feed and typeme.it/download resolve /releases/latest/download/: a model
# release taking "Latest" breaks both until an app release follows.
model-publish: model-verify
	@command -v gh >/dev/null || { echo "gh is not installed" >&2; exit 1; }
	gh release create $(TAG) --latest=false \
	  --title "$(SLUG) $(QUANT)" \
	  --notes "$(MODEL) converted and quantised to $(QUANT) with transcribe.cpp $(TRANSCRIBE). sha256 $(PINNED_SHA)" \
	  $(GGUF)
	@echo
	@echo "ModelStore.primaryURL:"
	@echo "https://github.com/$$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/download/$(TAG)/$(notdir $(GGUF))"

# The upload is 700MB over the wire and nothing else checks it landed intact.
model-verify-url:
	@url="https://github.com/$$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/download/$(TAG)/$(notdir $(GGUF))"; \
	echo "$$url"; \
	sha=$$(curl -fsSL "$$url" | shasum -a 256 | cut -d' ' -f1); \
	if [ "$$sha" != "$(PINNED_SHA)" ]; then \
		echo "the published asset hashes to $$sha, not $(PINNED_SHA)"; \
		exit 1; \
	fi; \
	echo "$$sha matches $(STORE)"

# The clean-up prompt, scored through the app's own PostProcessor. Needs a Mac
# with Apple Intelligence on.
eval:
	Scripts/cleanup-eval/run.sh

# The same cases on local GGUF models, e.g. make bench MODELS="a.gguf b.gguf".
bench:
	Scripts/llm-bench/run.sh $(MODELS)

# The onboarding image for the 🌐 key step, light and dark, from the
# screenshots in design/onboarding.
.PHONY: globe-key-image
globe-key-image:
	swift Scripts/globe-key-image.swift

$(DIARIZER_TAR):
	Scripts/diarizer-model.sh $(DIARIZER_REVISION) build/diarizer

diarizer-model: $(DIARIZER_TAR)

diarizer-model-sums: $(DIARIZER_TAR)
	@echo '    nonisolated static let fileName = "$(notdir $(DIARIZER_TAR))"'
	@echo '    nonisolated static let expectedBytes: Int64 = '$$(wc -c < $(DIARIZER_TAR) | tr -d ' ')
	@echo '    nonisolated static let sha256 = "'$$(shasum -a 256 $(DIARIZER_TAR) | cut -d' ' -f1)'"'

diarizer-model-verify: $(DIARIZER_TAR)
	@sha=$$(shasum -a 256 $(DIARIZER_TAR) | cut -d' ' -f1); \
	bytes=$$(wc -c < $(DIARIZER_TAR) | tr -d ' '); \
	if [ "$$sha" != "$(DIARIZER_PINNED_SHA)" ] || [ "$$bytes" != "$(DIARIZER_PINNED_BYTES)" ]; then \
		echo "$(DIARIZER_TAR) is not the file $(DIARIZER_STORE) pins."; \
		echo "  built  $$sha  $$bytes bytes"; \
		echo "  pinned $(DIARIZER_PINNED_SHA)  $(DIARIZER_PINNED_BYTES) bytes"; \
		echo "Run 'make diarizer-model-sums' and update $(DIARIZER_STORE) before publishing."; \
		exit 1; \
	fi; \
	echo "$$sha matches $(DIARIZER_STORE)"

# --latest=false for the reason model-publish gives.
diarizer-model-publish: diarizer-model-verify
	@command -v gh >/dev/null || { echo "gh is not installed" >&2; exit 1; }
	gh release create $(DIARIZER_TAG) --latest=false \
	  --title "speaker-diarization-coreml $(shell echo $(DIARIZER_REVISION) | cut -c1-8)" \
	  --notes "FluidInference/speaker-diarization-coreml at $(DIARIZER_REVISION): the offline diarizer's files (pyannote community-1 segmentation, WeSpeaker embeddings, PLDA), CC-BY-4.0, with the upstream NOTICE.md and LICENSE. sha256 $(DIARIZER_PINNED_SHA)" \
	  $(DIARIZER_TAR)
	@echo
	@echo "DiarizerModelStore.downloadURL:"
	@echo "https://github.com/$$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/download/$(DIARIZER_TAG)/$(notdir $(DIARIZER_TAR))"

diarizer-model-verify-url:
	@url="https://github.com/$$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/download/$(DIARIZER_TAG)/$(notdir $(DIARIZER_TAR))"; \
	echo "$$url"; \
	sha=$$(curl -fsSL "$$url" | shasum -a 256 | cut -d' ' -f1); \
	if [ "$$sha" != "$(DIARIZER_PINNED_SHA)" ]; then \
		echo "the published asset hashes to $$sha, not $(DIARIZER_PINNED_SHA)"; \
		exit 1; \
	fi; \
	echo "$$sha matches $(DIARIZER_STORE)"
