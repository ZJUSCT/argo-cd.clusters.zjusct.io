# Some snippets for K8S maintainance and debugging.

.PHONY: debug debug-pvc deploy

deploy:
	@echo "Deploying the application using Kustomize and Helm"
	kubectl kustomize --enable-helm $(KUSTOMIZE_DIR) | kubectl apply --server-side -f -

debug:
	@echo "Debugging a pod in a namespace"
	@echo "Usage: make debug NAMESPACE=<namespace> POD_NAME=<pod-name> CONTAINER_NAME=<container-name>"
	@echo "Example: make debug NAMESPACE=default POD_NAME=my-pod CONTAINER_NAME=my-container"
	kubectl debug \
		-it \
		-n $(NAMESPACE) $(POD_NAME) \
		--copy-to=$(POD_NAME)-debug \
		--container=$(CONTAINER_NAME) \
		--image=ubuntu:latest \
		-- bash

debug-pvc:
	@echo "Debugging a PVC in a namespace"
	@echo "Usage: make debug-pvc NAMESPACE=<namespace> PVC_NAME=<pvc-name>"
	@echo "Example: make debug-pvc NAMESPACE=default PVC_NAME=my-pvc"
	kubectl run pvc-debug \
		--rm -it \
		--restart=Never \
		-n $(NAMESPACE) \
		--image=ubuntu:latest \
		--overrides='{ "apiVersion": "v1", "kind": "Pod", "metadata": { "name": "pvc-debug" }, "spec": { "containers": [ { "name": "pvc-debug", "image": "ubuntu:latest", "stdin": true, "stdinOnce": false, "tty": true, "command": ["/bin/bash"], "volumeMounts": [ { "name": "debug-pvc", "mountPath": "/mnt/debug" } ] } ], "volumes": [ { "name": "debug-pvc", "persistentVolumeClaim": { "claimName": "$(PVC_NAME)" } } ] } }' \
		-- bash
