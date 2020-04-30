SHELL := /bin/bash

VARIANT ?= latest
HOMEDIR ?= https://github.com/amanibhavam/homedir
DOTFILES ?= https://github.com/amanibhavam/dotfiles

.PHONY: docs zt0 zt1

menu:
	@perl -ne 'printf("%10s: %s\n","$$1","$$2") if m{^([\w+-]+):[^#]+#\s(.+)$$}' Makefile

all: # Run everything except build
	$(MAKE) fmt
	$(MAKE) lint
	$(MAKE) docs
	$(MAKE) test

fmt: # Format with isort, black
	@echo
	drone exec --pipeline $@

lint: # Run pyflakes, mypy
	@echo
	drone exec --pipeline $@

test: # Run tests
	@echo
	drone exec --pipeline $@

docs: # Build docs
	@echo
	drone exec --pipeline $@

requirements: # Compile requirements
	@echo
	drone exec --pipeline $@

push: # Push to defn/home
	docker push defn/home

build: # Build home Docker image
	$(MAKE) os
	$(MAKE) update0
	$(MAKE) update1
	$(MAKE) variant

os: # Build os container
	cd b && docker build -t registry.eldri.ch/defn/home:$@ -f Dockerfile.$@ --no-cache .

update0: # Build base with homedir/dotfiles
	cd b && docker build -t registry.eldri.ch/defn/home:$@ -f Dockerfile.$@ --no-cache \
		--build-arg HOMEDIR="$(HOMEDIR)" \
		--build-arg DOTFILES="$(DOTFILES)" \
		.

update1: # Build initial install with homedir/dotfiles
	cd b && docker build -t registry.eldri.ch/defn/home:$@ -f Dockerfile.$@ --no-cache .

latest: # Build latest variant
	make VARIANT=latest variant

variant: # Build update with homedir/dotfiles
	cd b && docker build -t registry.eldri.ch/defn/home:$(VARIANT) -f Dockerfile.$(VARIANT) --no-cache .
	docker tag registry.eldri.ch/defn/home:$(VARIANT) defn/home:$(VARIANT)

warm: # Cache FROM images
	docker run --rm -ti -v $(shell pwd)/cache:/cache gcr.io/kaniko-project/warmer:latest --cache-dir=/cache --image=letfn/python-cli:latest

watch: # Watch for changes
	@trap 'exit' INT; while true; do fswatch -0 src content | while read -d "" event; do case "$$event" in *.py) figlet woke; make lint test; break; ;; *.md) figlet docs; make docs; ;; esac; done; sleep 1; done

logs: # Logs for docker-compose
	docker-compose logs -f

up: # Run home container with docker-compose
	ssh-keygen -R [localhost]:2222 || true
	docker-compose up -d

down: # Shut down home container
	docker-compose down

restart: # Restart home container
	docker-compose restart

recreate: # Recreate home container
	-$(MAKE) down 
	$(MAKE) up

recycle: # Rebuild and recreate home container
	$(MAKE) build
	$(MAKE) recreate

ssh: # ssh into home container
	ssh -A -p 2222 -o StrictHostKeyChecking=no app@localhost

top: # Monitor hyperkit processes
	top $(shell pgrep hyperkit | perl -pe 's{^}{-pid }')

zt0 zt1: # Launch multipass machine
	if ! test -d $(PWD)/data/$@/home/.git; then \
		git clone https://github.com/amanibhavam/homedir $(PWD)/data/$@/home/homedir; \
		(pushd $(PWD)/data/$@/home && mv homedir/.git . && git reset --hard && rm -rf homedir); \
	fi
	mkdir -p $(PWD)/data/$@/home/.asdf
	multipass delete --purge $@ || true
	multipass launch -m 4g -d 40g -c 2 -n $@ --cloud-init cloud-init.conf focal
	$@ exec bash -c 'while ! test -f /tmp/done.txt; do ps axuf; sleep 10; date; done'
	$@ exec sudo mkdir -p /data
	multipass mount $(PWD)/data/$@ $@:/data
	multipass mount $(PWD)/data/$@/home/.git $@:.git
	multipass mount $(PWD)/data/$@/home/.asdf $@:.asdf
	multipass mount $(PWD)/data/$@/home/venv $@:venv
	$@ exec git reset --hard
	cat ~/.dotfiles-repo | $@ exec tee .dotfiles-repo
	$@ exec make update
	$@ exec make upgrade
	$@ exec make install
	$@ exec mkdir -p work
	multipass mount "$(shell pwd)" $@:work/home
	$(MAKE) NAME=$@ kind-cluster
	$(MAKE) NAME=$@ kind-extras
	multipass unmount $@:work/home

kind-cluster:
	$(NAME) exec bash -c "source .bash_profile && cd work/home && env KUBECONFIG=/home/ubuntu/.kube/config kind create cluster --config $(NAME).yaml --name kind"
	$(NAME) exec bash -c "echo nameserver 8.8.8.8 | docker exec -i kind-control-plane tee /etc/resolv.conf"
	$(NAME) exec cat .kube/config | perl -pe 's{127.0.0.1:.*}{$(NAME):6443}; s{kind-kind}{$(NAME)}' > ~/.kube/$(NAME).conf

kind-extras:
	$(MAKE) cilium
	while $(NAME) ks get nodes | grep NotReady; do sleep 5; done
	while [[ "$$($(NAME) ks get -o json pods | jq -r '.items[].status | "\(.phase) \(.containerStatuses[].ready)"' | sort -u)" != "Running true" ]]; do $(NAME) ks get pods; sleep 5; echo; done
	$(MAKE) metal
	$(MAKE) nginx
	$(MAKE) traefik
	$(MAKE) hubble
	$(NAME) kt apply -f $(NAME)/

cilium:
	$(NAME) k apply -f cilium.yaml
	while [[ "$$($(NAME) ks get -o json pods | jq -r '.items[].status | "\(.phase) \(.containerStatuses[].ready)"' | sort -u)" != "Running true" ]]; do $(NAME) ks get pods; sleep 5; echo; done

metal:
	$(NAME) k create ns metallb-system || true
	$(NAME) kn metallb-system apply -f metal.yaml

cloudflare.yaml:
	cp $@.example $@

traefik: cloudflare.yaml
	$(NAME) k create ns traefik || true
	$(NAME) kt apply -f crds
	$(NAME) kt apply -f cloudflare.yaml
	$(NAME) kt apply -f traefik.yaml

argo:
	$(NAME) k create ns argo || true
	$(NAME) kn argo apply -f argo.yaml

hubble pihole openvpn nginx registry home kong:
	$(NAME) k apply -f $@.yaml
