#!/bin/sh
set -o errexit

## script to deploy kind cluster locally with nginx ingress controller or ambassador

## Usage: create-kind-cluster.sh -a [create|destroy] -n [nginx|ambassador]
while [[ "$#" -gt 0 ]]; do
  case $1 in
  -a | --action)
    ACTION="$2"
    shift
    ;;
  -n | --ingress-controller)
    INGRESS_CONTROLLER="$2"
    shift
    ;;
  *)
    echo "Unknown parameter passed: $1"
    exit 1
    ;;
  esac
  shift
done

if [[ $DEBUG == true ]]; then
  set -x
fi

if [[ "$ACTION" == "destroy" ]]; then
  echo "Creating kind cluster"
  kind delete cluster
  exit 0
fi

## create cluster with a private registry
## source https://kind.sigs.k8s.io/docs/user/local-registry/
# create registry container unless it already exists
reg_name='kind-registry'
reg_port='5001'
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  docker run \
    -d --restart=always -p "127.0.0.1:${reg_port}:5000" --name "${reg_name}" \
    registry:2
fi

# create a cluster with the local registry enabled in containerd
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${reg_port}"]
    endpoint = ["http://${reg_name}:5000"]
## custom config to enable ingress
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP

EOF

# connect the registry to the cluster network if not already connected
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  docker network connect "kind" "${reg_name}"
fi

# Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

if [[ $INGRESS_CONTROLLER == "nginx" ]]; then
  echo "Deploying nginx ingress controller"
  ## Install nginx ingress controller
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

  ## wait for ingress controller to be ready
  sleep 10
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=90s
# TODO: Currently not working with version 1.24 of k8s due to deprecated api version
elif [[ $INGRESS_CONTROLLER == "ambassador" ]]; then
  echo "Deploying ambassador ingress controller"
  kubectl apply -f https://github.com/datawire/ambassador-operator/releases/latest/download/ambassador-operator-crds.yaml
  kubectl apply -n ambassador -f https://github.com/datawire/ambassador-operator/releases/latest/download/ambassador-operator-kind.yaml
  sleep 10
  kubectl wait --timeout=180s -n ambassador --for=condition=deployed ambassadorinstallations/ambassador
fi