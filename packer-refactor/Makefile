export PACKER_LOG=1
export PACKER_LOG_PATH=packer.log

lint:
	cloud-init schema -c user-data
	packer fmt .
	packer init .
	packer validate .
docker-build:
	docker build -t harbor.clusters.zjusct.io/library/packer . --progress=plain --push
docker-shell:
	docker run --rm -it \
		-v $$(pwd):/workspace \
		-v /dev/kvm:/dev/kvm \
		--privileged \
		-w /workspace \
		harbor.clusters.zjusct.io/library/packer
docker-run:
	docker run --rm \
		-v $$(pwd):/workspace \
		-w /workspace \
		-v /dev/kvm:/dev/kvm \
		--privileged \
		harbor.clusters.zjusct.io/library/packer \
		-c "make debian-13-arm64"
%:
	rm -rf output-$@
	python3 packer.py $@
