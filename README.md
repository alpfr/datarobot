# DataRobot PoC on GKE — Runbook

This repo provisions a regional, VPC-native GKE cluster and the supporting
GCP plumbing (VPC, Cloud NAT, GCS buckets, IAM service accounts) needed to
deploy DataRobot via its enterprise Helm chart.

```
.
├── README.md
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── kubernetes/
    ├── storage-class.yaml
    └── values-poc.yaml
```

## Prerequisites

- `gcloud` CLI ≥ 460
- `terraform` ≥ 1.5
- `kubectl` ≥ 1.29 and the `gke-gcloud-auth-plugin`
  (`gcloud components install gke-gcloud-auth-plugin`)
- `helm` ≥ 3.14
- A GCP project with billing enabled, and an account that has
  `roles/owner` (or an equivalent custom role) on it for the duration of
  the PoC bootstrap.
- Credentials from your DataRobot SA: license key, private Helm repo URL +
  credentials, and image registry pull secret.

---

## 1. Authenticate `gcloud`

```bash
# Human user login (opens a browser)
gcloud auth login

# Application Default Credentials -- this is what Terraform will use
gcloud auth application-default login

# Pin your project + region
export PROJECT_ID="<your-gcp-project-id>"
export REGION="us-central1"
gcloud config set project "$PROJECT_ID"
gcloud config set compute/region "$REGION"
```

## 2. Run Terraform

```bash
cd terraform/

# One-time: state can live locally for a PoC. For prod, switch the backend
# to a GCS bucket.
terraform init

# Plan with the project ID injected.
terraform plan \
  -var "project_id=$PROJECT_ID" \
  -var "region=$REGION" \
  -out tfplan

# Apply. First apply takes ~10–15 minutes (cluster + node pools).
terraform apply tfplan
```

Useful outputs:

```bash
terraform output blob_buckets
terraform output datarobot_workload_service_account
terraform output kubectl_get_credentials_cmd
```

> **Lock down the control plane.** The default `master_authorized_cidrs`
> is `0.0.0.0/0` for PoC convenience. Override it with your office /
> bastion CIDR before going to production.

## 3. Wire `kubectl` to the new cluster

```bash
# Convenience: terraform prints the exact command.
eval "$(terraform output -raw kubectl_get_credentials_cmd)"

# Or run it explicitly:
gcloud container clusters get-credentials datarobot-poc-gke \
  --region "$REGION" --project "$PROJECT_ID"

kubectl get nodes -o wide
```

You should see nodes from both pools (`pool=system`, `pool=modeling`).

## 4. Apply the SSD StorageClass

```bash
cd ../kubernetes/
kubectl apply -f storage-class.yaml
kubectl get storageclass datarobot-ssd
```

## 5. Prepare the DataRobot namespace + secrets

```bash
kubectl create namespace datarobot

# License (from your DataRobot SA)
kubectl -n datarobot create secret generic datarobot-license \
  --from-file=license=./license.key

# Image-pull secret -- DataRobot SA gives you a manifest; apply it:
kubectl -n datarobot apply -f ./datarobot-regcred.yaml

# TLS cert (skip if you use cert-manager)
kubectl -n datarobot create secret tls datarobot-tls \
  --cert=./fullchain.pem --key=./privkey.pem
```

## 6. Edit `values-poc.yaml`

Open `kubernetes/values-poc.yaml` and replace every `<...>` placeholder:

- `global.imageRegistry` — DataRobot private registry hostname
- `global.serviceAccount.annotations` — paste the value of
  `terraform output -raw datarobot_workload_service_account`
- `blobStorage.gcs.*Bucket` — paste from `terraform output blob_buckets`
- `ingress.hostname` — your DNS name for the DataRobot UI

> The chart key paths in this template follow the public DataRobot Helm
> conventions but **always cross-check** against the chart version your SA
> provides:
> ```bash
> helm show values datarobot/datarobot --version <ver> > upstream-values.yaml
> ```

## 7. Add the DataRobot Helm repo and install

```bash
# Credentials come from your DataRobot SA.
helm repo add datarobot \
  "<https://helm.datarobot.com/enterprise>" \
  --username "<HELM_REPO_USER>" \
  --password "<HELM_REPO_PASSWORD>"

helm repo update

# Sanity check
helm search repo datarobot

# Install (PoC namespace = datarobot)
helm upgrade --install datarobot datarobot/datarobot \
  --namespace datarobot \
  --version "<chart-version>" \
  -f kubernetes/values-poc.yaml \
  --timeout 30m

# Watch rollout
kubectl -n datarobot get pods -w
```

## 8. Post-install smoke test

```bash
kubectl -n datarobot get ingress
# Resolve the LB IP and point your DNS record at it, then browse to
# https://<datarobot.example.com>
```

## Tear down (do this when the PoC is over!)

> Cost discipline: this stack is sized for a short PoC with Spot workers in
> a single zone. Even so, leaving it running for a week costs real money.
> Run `terraform destroy` as soon as you're done.


```bash
helm -n datarobot uninstall datarobot

cd terraform/
terraform destroy \
  -var "project_id=$PROJECT_ID" \
  -var "region=$REGION"
```

GCS buckets have `force_destroy = true` for the PoC, so `terraform destroy`
will delete their contents too. Remove that flag in `main.tf` for prod.
