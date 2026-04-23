INSIDE_DOCKER := $(shell test -f /.dockerenv && echo yes)
.DEFAULT_GOAL := debian-13-amd64

ifeq ($(INSIDE_DOCKER),yes)

lint:
	cloud-init schema -c user-data
	packer fmt .
	packer init .
	packer validate .

clean:
	rm -rf output-* .*.auto.pkrvars.json *.log

all: debian-13-amd64 archlinux-amd64 fedora-43-amd64

%:
	rm -rf output-$@
	python3 packer.py $@

else

# Host-only targets
build-docker:
	docker compose build packer --progress=plain --push

shell:
	docker compose run --rm -it packer

down:
	docker compose down --remove-orphans

# Proxy everything else into Docker
%:
	docker compose run --rm packer -c "make $@"

endif
