IMAGE ?= ledger-service:dev
SERVICE_DIR ?= ../ledger-service
CLUSTER = ledger

# kind nodes cannot pull from registries on this network, so every image is pulled on the host and side-loaded.
IMAGES = ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1 ghcr.io/cloudnative-pg/postgresql:17 \
	quay.io/strimzi/operator:1.3.0 quay.io/strimzi/kafka:1.3.0-kafka-4.3.1 \
	registry.k8s.io/ingress-nginx/controller:v1.12.1 registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.2 \
	registry.k8s.io/metrics-server/metrics-server:v0.7.2
OBS_IMAGES = docker.io/grafana/grafana:13.2.4-distroless quay.io/kiwigrid/k8s-sidecar:2.14.1 \
	quay.io/prometheus-operator/prometheus-operator:v0.94.1 quay.io/prometheus-operator/prometheus-config-reloader:v0.94.1 \
	quay.io/prometheus-operator/prometheus-config-reloader:v0.94.0 quay.io/prometheus/prometheus:v3.15.0-distroless \
	quay.io/prometheus/node-exporter:v1.12.1-distroless registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0 \
	docker.io/grafana/loki:3.6.11 docker.io/grafana/tempo:2.9.0 docker.io/grafana/alloy:v1.21.1

.PHONY: up cluster load-images image platform operators observability deploy down
up: cluster load-images image platform operators observability deploy

cluster:
	kind create cluster --config kind/cluster.yaml
	kind/helpers/fix-dns.sh $(CLUSTER)
	kubectl -n kube-system rollout restart deploy/coredns

load-images:
	for i in $(IMAGES) $(OBS_IMAGES); do docker pull -q $$i && kind load docker-image $$i --name $(CLUSTER); done

image:
	cd $(SERVICE_DIR) && ./gradlew bootJar copyOtelAgent && docker build -t $(IMAGE) .
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

observability:
	helm upgrade --install kps platform/charts/kube-prometheus-stack-92.11.0.tgz -n monitoring --create-namespace \
		-f platform/values/kube-prometheus-stack.yaml --wait --timeout 8m
	helm upgrade --install loki platform/charts/loki-7.3.0.tgz -n monitoring -f platform/values/loki.yaml --wait --timeout 5m
	helm upgrade --install tempo platform/charts/tempo-1.24.4.tgz -n monitoring -f platform/values/tempo.yaml --wait --timeout 5m
	helm upgrade --install alloy platform/charts/alloy-1.14.1.tgz -n monitoring -f platform/values/alloy.yaml --wait --timeout 5m

deploy:
	helm upgrade --install ledger charts/ledger -n ledger -f charts/ledger/values-dev.yaml

down:
	kind delete cluster --name $(CLUSTER)
