INSIDE_DOCKER := $(shell test -f /.dockerenv && echo yes)
ON_MACOS := $(shell uname -s | grep -q Darwin && echo yes)
.DEFAULT_GOAL := debian-13-amd64

ifeq ($(filter yes,$(INSIDE_DOCKER) $(ON_MACOS)),yes)

lint:
	cloud-init schema -c user-data || true # macos doesn't have cloud-init
	packer fmt .
	packer init .
	packer validate .

copy-module:
	cp modules*/* /tmp
	cp squid.crt /tmp

clean:
	rm -rf output

all-amd64: debian-13-amd64 ubuntu-26.04-amd64 \
	archlinux-amd64 fedora-43-amd64 rocky-9-amd64

all-arm64: debian-13-arm64 ubuntu-26.04-arm64

all-riscv64: debian-13-riscv64 ubuntu-26.04-riscv64

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
	docker compose run --rm -t packer -c "make -j $@"

endif
