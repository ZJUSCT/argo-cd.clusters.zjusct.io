SHELL := /bin/bash
.PHONY: help debug-pod debug-container debug-pvc clean

# Container Configuration
DEBUG_IMAGE := harbor.clusters.zjusct.io/library/ubuntu:latest

# Debug Pod Configuration
DEBUG_POD_TARGET := packer-run-ubuntu-8f5fh-build-image-pod
DEBUG_POD_NAME := debug-pod
DEBUG_CONTAINER_NAME := step-packer-init
DEBUG_NAMESPACE := tekton

# Debug PVC Configuration
DEBUG_PVC_NAME := pvc-f6e5474dea
DEBUG_PVC_MOUNT_PATH := /mnt/debug-pvc

clean:
	@echo "Warning: This will remove all gitignored files in the repository."
	@read -p "Are you sure you want to proceed? (y/N) " -n 1 -r; echo
	git clean -fdX; \

# Help target
help:
	@echo "Available targets:"
	@echo "  debug-pod        Run a temporary debug pod with Ubuntu image"
	@echo "  debug-container  Debug a specific pod container (requires DEBUG_POD_TARGET, DEBUG_CONTAINER_NAME)"
	@echo "  debug-pvc        Mount and debug a PVC in the cluster"

# Debug Targets
debug-pod:
	kubectl run -it --rm debug --image=$(DEBUG_IMAGE) --restart=Never -- bash

debug-container:
	kubectl debug $(DEBUG_POD_TARGET) \
		-n $(DEBUG_NAMESPACE) \
		--copy-to=$(DEBUG_POD_NAME) \
		--container=$(DEBUG_CONTAINER_NAME) \
		--profile=general \
		-it -- sh

debug-pvc:
	kubectl run debug-pvc \
		-it \
		--rm \
		--image=$(DEBUG_IMAGE) \
		--namespace=$(DEBUG_NAMESPACE) \
		--restart=Never \
		--overrides='{"spec":{"volumes":[{"name":"debug-pvc","persistentVolumeClaim":{"claimName":"$(DEBUG_PVC_NAME)"}}],"containers":[{"command":["sleep","infinity"],"tty": true,"stdin": true,"name":"debug-pvc-container","image":"$(DEBUG_IMAGE)","volumeMounts":[{"name":"debug-pvc","mountPath":"$(DEBUG_PVC_MOUNT_PATH)"}]}]}}' \
		-- bash
