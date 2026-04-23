export PACKER_LOG=1
export PACKER_LOG_PATH=packer.log
TARGET?=ubuntu-20.04-amd64-ascend

lint:
	cloud-init schema -c user-data
	packer fmt .
	packer init .
	packer validate .
build:
	docker compose build packer --progress=plain --push
shell:
	docker compose run --rm -it packer
run:
	docker compose run --rm packer \
		-c "make $(TARGET)"
down:
	docker compose down --remove-orphans
clean:
	rm -rf output-* .*.auto.pkrvars.json *.log
%:
	rm -rf output-$@
	python3 packer.py $@
