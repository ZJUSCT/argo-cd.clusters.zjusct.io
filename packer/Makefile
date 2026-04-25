INSIDE_DOCKER := $(shell test -f /.dockerenv && echo yes)
ON_MACOS := $(shell uname -s | grep -q Darwin && echo yes)
.DEFAULT_GOAL := all

ifeq ($(filter yes,$(INSIDE_DOCKER) $(ON_MACOS)),yes)

lint:
	cloud-init schema -c user-data || true
	packer fmt .
	packer init .
	packer validate .

copy-module:
	cp modules*/* /tmp
	cp squid.crt /tmp

clean:
	rm -rf output

all: debian-13-amd64 debian-13-arm64 debian-13-riscv64 \
	ubuntu-25.10-amd64 ubuntu-25.10-arm64 ubuntu-25.10-riscv64 \
	ubuntu-20.04-amd64-ascend \
	archlinux-amd64 fedora-43-amd64 rocky-9-amd64

%:
	rm -rf output/$@
	python3 packer.py $@

else

# Host-only targets (Linux)
build-docker:
	docker compose build packer --progress=plain --push

shell-packer:
	docker compose run --rm -it packer

shell-test:
	docker compose run --rm -it test

down:
	docker compose down --remove-orphans

# Proxy everything else into Docker
%:
	docker compose run --rm packer -c "make -j $@"

endif
