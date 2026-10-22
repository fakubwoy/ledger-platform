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
IMAGES = ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1 ghcr.io/cloudnative-pg/postgresql:17 \
	quay.io/strimzi/operator:1.3.0 quay.io/strimzi/kafka:1.3.0-kafka-4.3.1
load-images:
	for i in $(IMAGES); do docker pull -q $$i && kind load docker-image $$i --name ledger; done

operators:
	helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace --wait
	helm upgrade --install strimzi strimzi/strimzi-kafka-operator -n strimzi-system --create-namespace \
		--set 'watchNamespaces={ledger}' --wait
