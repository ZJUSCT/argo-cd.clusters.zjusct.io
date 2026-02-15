debug:
	# run a ubuntu image as debug pod
	kubectl run -it --rm debug --image=ubuntu --restart=Never -- bash
