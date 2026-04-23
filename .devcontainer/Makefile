IMAGE := harbor.clusters.zjusct.io/library/devcontainer-k8s

.PHONY: all
all:
	docker build -t $(IMAGE) . --progress=plain --push
