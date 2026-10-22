IMAGE ?= ledger-service:dev
SERVICE_DIR ?= ../ledger-service
CLUSTER = ledger

# kind nodes cannot pull from registries on this network, so every image is pulled on the host and side-loaded.
IMAGES = ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1 ghcr.io/cloudnative-pg/postgresql:17 \
	quay.io/strimzi/operator:1.3.0 quay.io/strimzi/kafka:1.3.0-kafka-4.3.1 \
	registry.k8s.io/ingress-nginx/controller:v1.12.1 registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.2 \
	registry.k8s.io/metrics-server/metrics-server:v0.7.2

.PHONY: up cluster load-images image platform operators deploy down
up: cluster load-images image platform operators deploy

cluster:
	kind create cluster --config kind/cluster.yaml

load-images:
	for i in $(IMAGES); do docker pull -q $$i && kind load docker-image $$i --name $(CLUSTER); done

image:
	cd $(SERVICE_DIR) && ./gradlew bootJar && docker build -t $(IMAGE) .
	kind load docker-image $(IMAGE) --name $(CLUSTER)

# ingress-nginx and metrics-server are vendored in platform/ so the versions are pinned.
platform:
	kubectl apply -f platform/ingress-nginx.yaml -f platform/metrics-server.yaml
	kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
	kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s

operators:
	kubectl create namespace ledger --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install cnpg platform/charts/cloudnative-pg-0.29.1.tgz -n cnpg-system --create-namespace --wait
	helm upgrade --install strimzi platform/charts/strimzi-kafka-operator-1.3.0.tgz -n strimzi-system --create-namespace \
		--set 'watchNamespaces={ledger}' --wait

deploy:
	helm upgrade --install ledger charts/ledger -n ledger -f charts/ledger/values-dev.yaml

down:
	kind delete cluster --name $(CLUSTER)
