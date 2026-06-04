CONTAINER_ENGINE ?= docker
IMAGE_NAME ?= ubuntu24-ai-sandbox
IMAGE_TAG ?= latest
IMAGE := $(IMAGE_NAME):$(IMAGE_TAG)

USERNAME ?= devuser
USER_UID ?= 1000
USER_GID ?= 1000

.PHONY: image
image:
	$(CONTAINER_ENGINE) build \
		-f images/Dockerfile \
		--build-arg USERNAME=$(USERNAME) \
		--build-arg USER_UID=$(USER_UID) \
		--build-arg USER_GID=$(USER_GID) \
		-t $(IMAGE) \
		.