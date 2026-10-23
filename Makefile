CLUSTER = ledger

# `make up` builds everything on a fresh laptop. The ledger itself is deployed by Argo CD from GitHub
# (argocd/ledger.yaml); code changes ship through ledger-service CI, not from here.
# LITE=1 skips Loki, Tempo and Alloy (logs and traces). It saves only about 0.4 GiB (measured); most memory
# goes to the ledger replicas (about 620 MiB each), Prometheus and Kafka.
.PHONY: up cluster platform operators observability argocd down
up: cluster platform operators observability argocd

cluster:
	kind create cluster --config kind/cluster.yaml
	kind/helpers/fix-dns.sh $(CLUSTER)
	kubectl -n kube-system rollout restart deploy/coredns

# ingress-nginx and metrics-server are vendored in platform/ so the versions are pinned.
platform:
	kubectl apply -f platform/ingress-nginx.yaml -f platform/metrics-server.yaml
	kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s
	kubectl -n kube-system rollout status deploy/metrics-server --timeout=300s

operators:
	kubectl create namespace ledger --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install cnpg platform/charts/cloudnative-pg-0.29.1.tgz -n cnpg-system --create-namespace --wait
	helm upgrade --install strimzi platform/charts/strimzi-kafka-operator-1.3.0.tgz -n strimzi-system --create-namespace \
		--set 'watchNamespaces={ledger}' --wait

observability:
	helm upgrade --install kps platform/charts/kube-prometheus-stack-92.11.0.tgz -n monitoring --create-namespace \
		-f platform/values/kube-prometheus-stack.yaml --wait --timeout 10m
ifndef LITE
	helm upgrade --install loki platform/charts/loki-7.3.0.tgz -n monitoring -f platform/values/loki.yaml --wait --timeout 5m
	helm upgrade --install tempo platform/charts/tempo-1.24.4.tgz -n monitoring -f platform/values/tempo.yaml --wait --timeout 5m
	helm upgrade --install alloy platform/charts/alloy-1.14.1.tgz -n monitoring -f platform/values/alloy.yaml --wait --timeout 5m
endif

argocd:
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd --server-side --force-conflicts -f platform/argocd-install.yaml
	kubectl apply --server-side --force-conflicts -f platform/argocd-config.yaml
	kubectl -n argocd rollout restart deploy/argocd-server deploy/argocd-repo-server
	kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
	kubectl apply -f argocd/ledger.yaml
	@echo "Argo CD is syncing the ledger: kubectl -n argocd get application ledger -w"

down:
	kind delete cluster --name $(CLUSTER)
	docker rm -f kind-dns
