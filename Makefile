debug:
	# run a ubuntu image as debug pod
	kubectl run -it --rm debug --image=harbor.clusters.zjusct.io/library/ubuntu:latest --restart=Never -- bash
