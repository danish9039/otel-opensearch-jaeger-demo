#!/bin/bash
set -euo pipefail
source cluster-config.env

echo " Using existing VCN: $OCI_VCN_OCID"
echo " Using existing LB subnet: $OCI_PUBLIC_LB_SUBNET_OCID"
echo " Using existing worker subnet: $OCI_WORKER_SUBNET_OCID"

# Create OKE cluster in existing networking
CLUSTER_ID=$(oci ce cluster create \
  --compartment-id "$OCI_COMPARTMENT_ID" \
  --name "jaeger-demo-cluster" \
  --vcn-id "$OCI_VCN_OCID" \
  --service-lb-subnet-ids "[\"$OCI_PUBLIC_LB_SUBNET_OCID\"]" \
  --kubernetes-version "v1.28.2" \
  --cluster-pod-network-options '{"cniType":"OCI_VCN_IP_NATIVE"}' \
  --wait-for-state ACTIVE \
  --query 'data.id' --raw-output)

echo "OKE Cluster created: $CLUSTER_ID"

# Create Node Pool on existing worker subnet
NODE_POOL_ID=$(oci ce node-pool create \
  --compartment-id "$OCI_COMPARTMENT_ID" \
  --cluster-id "$CLUSTER_ID" \
  --name "jaeger-demo-nodes" \
  --kubernetes-version "v1.28.2" \
  --node-shape "VM.Standard.E4.Flex" \
  --node-shape-config '{"ocpus":4,"memoryInGBs":32}' \
  --subnet-ids "[\"$OCI_WORKER_SUBNET_OCID\"]" \
  --size 3 \
  --wait-for-state ACTIVE \
  --query 'data.id' --raw-output)

echo "Node Pool created: $NODE_POOL_ID"

# Save cluster info
cat > cluster-config.env <<EOF
OCI_COMPARTMENT_ID=$OCI_COMPARTMENT_ID
OCI_VCN_OCID=$OCI_VCN_OCID
OCI_PUBLIC_LB_SUBNET_OCID=$OCI_PUBLIC_LB_SUBNET_OCID
OCI_WORKER_SUBNET_OCID=$OCI_WORKER_SUBNET_OCID
CLUSTER_ID=$CLUSTER_ID
NODE_POOL_ID=$NODE_POOL_ID
EOF

