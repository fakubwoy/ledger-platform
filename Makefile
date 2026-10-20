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
