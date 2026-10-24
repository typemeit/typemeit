# The speech model. The app itself builds with xcodegen and xcodebuild -- see
# CLAUDE.md -- and nothing here touches it.
#
#   make asr-model          fetch the speech model's files and tar them
#   make asr-model-sums     print the ModelStore.swift constants for the tar
#   make asr-model-verify   check the tar against what ModelStore.swift pins
#   make asr-model-publish  put the tar on typeme.it/models and print its URL
#   make asr-model-verify-url   re-download the published tar and hash it
#   make eval               score the clean-up prompt on Apple Intelligence
#   make meeting-eval       score meeting summaries and titles on Apple Intelligence
#   make asr-eval ARGS=...  score speech models and diarizers against AssemblyAI (Scripts/asr-eval/README.md)
#   make asr-eval-test      unit tests for the asr-eval scoring
#   make model-trials       build docs/model-trials.md and typeme.it/models from docs/model-trials.json
#   make bench MODELS=...   score the same cases on local GGUF models
#   make globe-key-image    rebuild the onboarding 🌐 key image from design/onboarding
#   make diarizer-model     fetch both speaker models' files and tar them
#   make diarizer-model-sums    print the DiarizerModelStore.swift constants for the tar
#   make diarizer-model-verify  check the tar against what DiarizerModelStore.swift pins
#   make diarizer-model-publish put the tar on typeme.it/models and print its URL
#   make diarizer-model-verify-url  re-download the published tar and hash it

# The speech model: Parakeet Ultra's Core ML files (FluidAudio's
# AsrModelVersion.ultra) at a pinned Hugging Face revision, mirrored to
# typeme.it in one tar so the app never fetches from Hugging Face and gets
# exactly the files that were tested.
ASR_REVISION ?= 95eaa59a39d4394f047a4dc5cce480388a60d1b6
ASR_TAR := build/asr/parakeet-ultra-$(shell echo $(ASR_REVISION) | cut -c1-8).tar

# Where the app downloads models from: the typemeit-releases R2 bucket, served
# by worker.js. The file names carry their version, so a new model is a new key.
MODELS_URL := https://typeme.it/models
R2_PUT := npm ci --silent --prefix Scripts/r2-put && node Scripts/r2-put/put.mjs
IMMUTABLE := public, max-age=31536000, immutable

# What the shipped app will accept. It hashes the file after downloading and
# throws away anything that does not match, so publishing a file that disagrees
# with these is publishing a download that can only fail.
STORE := TypeMeIt/ModelStore.swift
PINNED_SHA := $(shell sed -n 's/.*let sha256 = "\([0-9a-f]*\)".*/\1/p' $(STORE))
PINNED_BYTES := $(shell sed -n 's/.*let expectedBytes: Int64 = \([0-9_]*\).*/\1/p' $(STORE) | tr -d _)

# The speaker models (docs/meetings.md 8.2): the offline diarizer's files at
# the Hugging Face revision FluidAudio pins (Sources/FluidAudio/ModelNames.swift,
# Repo.diarizer.revision) and Nemotron 3 Diarization's, mirrored to typeme.it
# in one tar so the app never fetches from Hugging Face and gets exactly the
# files that were tested.
DIARIZER_REVISION ?= df2625ac79a7ac6b65ad868fee6d80f320da4232
# Nemotron 3 Diarization's CoreML conversion of the general-access checkpoint
# (FluidAudio's ModelNames.Nemotron3.weightsVersion ga-2026-09-23).
NEMOTRON_DIARIZER_REVISION ?= 25a90f97f254428d4b30374b76af9c74fdee8327
DIARIZER_TAR := build/diarizer/speaker-models-$(shell echo $(DIARIZER_REVISION) | cut -c1-8)-$(shell echo $(NEMOTRON_DIARIZER_REVISION) | cut -c1-8).tar
DIARIZER_STORE := TypeMeIt/Meetings/DiarizerModelStore.swift
DIARIZER_PINNED_SHA := $(shell sed -n 's/.*let sha256 = "\([0-9a-f]*\)".*/\1/p' $(DIARIZER_STORE))
DIARIZER_PINNED_BYTES := $(shell sed -n 's/.*let expectedBytes: Int64 = \([0-9_]*\).*/\1/p' $(DIARIZER_STORE) | tr -d _)

.DEFAULT_GOAL := help
.PHONY: help asr-model asr-model-sums asr-model-verify asr-model-publish asr-model-verify-url eval meeting-eval asr-eval asr-eval-test model-trials bench \
	diarizer-model diarizer-model-sums diarizer-model-verify diarizer-model-publish diarizer-model-verify-url

help:
	@sed -n 's/^#   //p' Makefile

# A file target, so a second run does not refetch several hundred MB.
$(ASR_TAR):
	Scripts/asr-model.sh $(ASR_REVISION) build/asr

asr-model: $(ASR_TAR)

asr-model-sums: $(ASR_TAR)
	@echo '    nonisolated static let fileName = "$(notdir $(ASR_TAR))"'
	@echo '    nonisolated static let expectedBytes: Int64 = '$$(wc -c < $(ASR_TAR) | tr -d ' ')
	@echo '    nonisolated static let sha256 = "'$$(shasum -a 256 $(ASR_TAR) | cut -d' ' -f1)'"'

asr-model-verify: $(ASR_TAR)
	@sha=$$(shasum -a 256 $(ASR_TAR) | cut -d' ' -f1); \
	bytes=$$(wc -c < $(ASR_TAR) | tr -d ' '); \
	if [ "$$sha" != "$(PINNED_SHA)" ] || [ "$$bytes" != "$(PINNED_BYTES)" ]; then \
		echo "$(ASR_TAR) is not the file $(STORE) pins."; \
		echo "  built  $$sha  $$bytes bytes"; \
		echo "  pinned $(PINNED_SHA)  $(PINNED_BYTES) bytes"; \
		echo "Run 'make asr-model-sums' and update $(STORE) before publishing."; \
		exit 1; \
	fi; \
	echo "$$sha matches $(STORE)"

# Verified first: uploading a file the app will reject wastes the upload and
# leaves a download that cannot be installed.
asr-model-publish: asr-model-verify
	$(R2_PUT) models/$(notdir $(ASR_TAR)) $(ASR_TAR) application/x-tar "$(IMMUTABLE)"
	@echo "$(MODELS_URL)/$(notdir $(ASR_TAR))"

# The upload is hundreds of MB over the wire and nothing else checks it landed intact.
asr-model-verify-url:
	@url="$(MODELS_URL)/$(notdir $(ASR_TAR))"; \
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

# Meeting summaries and titles on written test meetings, through the app's own
# MeetingSummary. Needs a Mac with Apple Intelligence on.
meeting-eval:
	Scripts/meeting-eval/run.sh

# Speech models and diarizers scored against an AssemblyAI reference whose
# disagreements were hand-checked, e.g. make asr-eval ARGS="run shipped".
asr-eval:
	python3 Scripts/asr-eval/asr_eval.py $(ARGS)

asr-eval-test:
	cd Scripts/asr-eval && python3 -m unittest discover -s tests

# docs/model-trials.json is the trial log; this writes the Markdown table and
# the web page from it.
model-trials:
	python3 Scripts/model-trials.py

# The same cases on local GGUF models, e.g. make bench MODELS="a.gguf b.gguf".
bench:
	Scripts/llm-bench/run.sh $(MODELS)

# The onboarding image for the 🌐 key step, light and dark, from the
# screenshots in design/onboarding.
.PHONY: globe-key-image
globe-key-image:
	swift Scripts/globe-key-image.swift

$(DIARIZER_TAR):
	Scripts/diarizer-model.sh $(DIARIZER_REVISION) $(NEMOTRON_DIARIZER_REVISION) build/diarizer

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

diarizer-model-publish: diarizer-model-verify
	$(R2_PUT) models/$(notdir $(DIARIZER_TAR)) $(DIARIZER_TAR) application/x-tar "$(IMMUTABLE)"
	@echo "$(MODELS_URL)/$(notdir $(DIARIZER_TAR))"

diarizer-model-verify-url:
	@url="$(MODELS_URL)/$(notdir $(DIARIZER_TAR))"; \
	echo "$$url"; \
	sha=$$(curl -fsSL "$$url" | shasum -a 256 | cut -d' ' -f1); \
	if [ "$$sha" != "$(DIARIZER_PINNED_SHA)" ]; then \
		echo "the published asset hashes to $$sha, not $(DIARIZER_PINNED_SHA)"; \
		exit 1; \
	fi; \
	echo "$$sha matches $(DIARIZER_STORE)"
