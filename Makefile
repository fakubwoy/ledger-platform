# Milestone 1 targets; `make up` grows as milestones land.
IMAGE ?= ledger-service:dev
SERVICE_DIR ?= ../ledger-service

cluster:
	kind create cluster --config kind/cluster.yaml

image:
	cd $(SERVICE_DIR) && ./gradlew bootJar && docker build -t $(IMAGE) .
	kind load docker-image $(IMAGE) --name ledger

deploy:
	kubectl apply -f k8s/

down:
	kind delete cluster --name ledger

# kind nodes cannot pull from registries on this network, so pull on the host and side-load.
load-images:
	for i in postgres:16 apache/kafka:3.9.0; do docker pull $$i && kind load docker-image $$i --name ledger; done
