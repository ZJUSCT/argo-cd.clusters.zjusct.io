IMAGE := harbor.clusters.zjusct.io/library/devcontainer-k8s

build:
	docker build -t $(IMAGE) . --progress=plain

push: build
	docker push $(IMAGE)

.PHONY: build push
