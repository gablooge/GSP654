#!/bin/bash

gcloud services enable \
    container.googleapis.com \
    compute.googleapis.com \
    monitoring.googleapis.com \
    logging.googleapis.com \
    cloudtrace.googleapis.com \
    meshca.googleapis.com \
    meshtelemetry.googleapis.com \
    meshconfig.googleapis.com \
    iamcredentials.googleapis.com \
    anthos.googleapis.com \
    gkeconnect.googleapis.com \
    gkehub.googleapis.com \
    cloudresourcemanager.googleapis.com

export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} \
    --format="value(projectNumber)")
export CLUSTER_NAME=central
export CLUSTER_ZONE=us-central1-b
export WORKLOAD_POOL=${PROJECT_ID}.svc.id.goog
export MESH_ID="proj-${PROJECT_NUMBER}"

gcloud projects get-iam-policy $PROJECT_ID \
    --flatten="bindings[].members" \
    --filter="bindings.members:user:$(gcloud config get-value core/account 2>/dev/null)"

gcloud config set compute/zone ${CLUSTER_ZONE}
gcloud beta container clusters create ${CLUSTER_NAME} \
    --machine-type=n1-standard-4 \
    --num-nodes=4 \
    --workload-pool=${WORKLOAD_POOL} \
    --enable-stackdriver-kubernetes \
    --subnetwork=default \
    --release-channel=regular \
    --labels mesh_id=${MESH_ID}

kubectl auth can-i '*' '*' --all-namespaces

gcloud iam service-accounts create connect-sa

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
 --member="serviceAccount:connect-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
 --role="roles/gkehub.connect"

gcloud iam service-accounts keys create connect-sa-key.json \
  --iam-account=connect-sa@${PROJECT_ID}.iam.gserviceaccount.com

gcloud container hub memberships register ${CLUSTER_NAME}-connect \
   --gke-cluster=${CLUSTER_ZONE}/${CLUSTER_NAME}  \
   --service-account-key-file=./connect-sa-key.json

curl --request POST \
  --header "Authorization: Bearer $(gcloud auth print-access-token)" \
  --data '' \
  https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}:initialize

curl -LO https://storage.googleapis.com/gke-release/asm/istio-1.6.11-asm.1-linux-amd64.tar.gz

curl -LO https://storage.googleapis.com/gke-release/asm/istio-1.6.11-asm.1-linux-amd64.tar.gz.1.sig
openssl dgst -verify /dev/stdin -signature istio-1.6.11-asm.1-linux-amd64.tar.gz.1.sig istio-1.6.11-asm.1-linux-amd64.tar.gz <<'EOF'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEWZrGCUaJJr1H8a36sG4UUoXvlXvZ
wQfk16sxprI2gOJ2vFFggdq3ixF2h4qNBt0kI7ciDhgpwS8t+/960IsIgw==
-----END PUBLIC KEY-----
EOF

tar xzf istio-1.6.11-asm.1-linux-amd64.tar.gz
cd istio-1.6.11-asm.1
export PATH=$PWD/bin:$PATH

sudo apt-get install google-cloud-sdk-kpt
mkdir ${CLUSTER_NAME}
cd ${CLUSTER_NAME}

kpt pkg get https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages@1.6.8-asm.9 asm

cd asm

kpt cfg set asm gcloud.container.cluster ${CLUSTER_NAME}
kpt cfg set asm gcloud.project.environProjectNumber ${PROJECT_NUMBER}
kpt cfg set asm gcloud.core.project ${PROJECT_ID}
kpt cfg set asm gcloud.compute.location ${CLUSTER_ZONE}
kpt cfg set asm anthos.servicemesh.profile asm-gcp

istioctl install -f asm/cluster/istio-operator.yaml

kubectl wait --for=condition=available --timeout=600s deployment \
    --all -n istio-system

asmctl validate

kubectl label namespace default istio-injection=enabled --overwrite

cd ~/istio-1.6.11-asm.1
cat samples/bookinfo/platform/kube/bookinfo.yaml

kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml

kubectl apply -f samples/bookinfo/networking/bookinfo-gateway.yaml

kubectl exec -it $(kubectl get pod -l app=ratings \
    -o jsonpath='{.items[0].metadata.name}') \
    -c ratings -- curl productpage:9080/productpage | grep -o "<title>.*</title>"


