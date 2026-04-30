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
- A GCP project with billing enabled.
- Credentials from your DataRobot SA: license key, private Helm repo URL +
  credentials, and image registry pull secret.

---

## IAM and service accounts

Three identity layers are involved. Get them straight before running
anything — most PoC failures are IAM, not code.

### 0. Operator (the human running Terraform)

The Google account you `gcloud auth application-default login` with
needs to be able to enable APIs, create networks, GKE clusters,
service accounts, IAM bindings, and GCS buckets. The simplest grant:

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="user:you@example.com" --role="roles/owner"
```

If your org doesn't allow `roles/owner`, the minimum equivalent set is:

| Role | Why |
|---|---|
| `roles/serviceusage.serviceUsageAdmin` | enable required APIs |
| `roles/compute.networkAdmin` | VPC, subnet, router, NAT |
| `roles/compute.securityAdmin` | firewall rules implicitly created by GKE |
| `roles/container.admin` | create/manage GKE cluster + node pools |
| `roles/iam.serviceAccountAdmin` | create the two service accounts below |
| `roles/iam.serviceAccountUser` | let GKE attach the node SA to nodes |
| `roles/resourcemanager.projectIamAdmin` | bind project-level roles to the node SA |
| `roles/storage.admin` | create GCS buckets and bind IAM on them |

You only need these for the bootstrap apply. Day-2 operators can run
with much less.

### 1. Service accounts created by Terraform

| GCP Service Account | Purpose | Roles granted |
|---|---|---|
| `datarobot-poc-gke-nodes@<PROJECT_ID>.iam.gserviceaccount.com` | Identity attached to every GKE node VM. | `roles/logging.logWriter`, `roles/monitoring.metricWriter`, `roles/monitoring.viewer`, `roles/stackdriver.resourceMetadata.writer`, `roles/artifactregistry.reader` |
| `datarobot-poc-app@<PROJECT_ID>.iam.gserviceaccount.com` | Workload-Identity target — DataRobot pods impersonate this SA. | `roles/storage.objectAdmin` scoped to the three PoC buckets only |

Why two and not one: the node SA is shared by every workload on the
node, so we keep its powers tiny (just enough for kubelet + image
pulls). Anything DataRobot itself needs (GCS access) lives on the *app*
SA, which only DataRobot's pods can mint tokens for.

### 2. Workload Identity binding

Terraform also creates the cross-domain binding that lets a Kubernetes
ServiceAccount (KSA) impersonate the GCP SA:

```
GCP SA: datarobot-poc-app
   └── roles/iam.workloadIdentityUser granted to:
        serviceAccount:<PROJECT_ID>.svc.id.goog[datarobot/datarobot-app]
```

Read that as: "any pod in the `datarobot` namespace running under a KSA
named `datarobot-app` may obtain credentials for `datarobot-poc-app`."
Two requirements must hold for it to actually work at runtime:

1. The Kubernetes SA must exist with that exact name + namespace.
2. The KSA must be annotated with the GCP SA email.

The Helm chart's `values-poc.yaml` already does both:

```yaml
global:
  serviceAccount:
    create: true
    name: "datarobot-app"
    annotations:
      iam.gke.io/gcp-service-account: "datarobot-poc-app@<PROJECT_ID>.iam.gserviceaccount.com"
```

After `terraform apply`, paste the real email from
`terraform output -raw datarobot_workload_service_account` into that
annotation. **If you change the KSA name or namespace, also change
`workload_identity_binding` in `terraform/main.tf` to match — they have
to be identical strings.**

### 3. Verify before installing the chart

```bash
# Did Terraform create both SAs?
gcloud iam service-accounts list --filter="email ~ datarobot-poc" \
  --project "$PROJECT_ID"

# Are bucket-level roles on the app SA?
for b in $(terraform -chdir=terraform output -json blob_buckets | jq -r '.[]'); do
  echo "=== $b ==="
  gcloud storage buckets get-iam-policy "gs://$b" \
    --format="table(bindings.role,bindings.members)"
done

# Is the Workload Identity binding present?
gcloud iam service-accounts get-iam-policy \
  "$(terraform -chdir=terraform output -raw datarobot_workload_service_account)" \
  --project "$PROJECT_ID"
```

You should see `roles/iam.workloadIdentityUser` granted to
`serviceAccount:<PROJECT_ID>.svc.id.goog[datarobot/datarobot-app]`. If
that line is missing the chart will install but DataRobot pods will
fail GCS calls with `401 UNAUTHENTICATED`.

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
  (this is what wires Workload Identity; see *IAM and service accounts*
  above)
- `blobStorage.gcs.*Bucket` — paste from `terraform output blob_buckets`
- `ingress.hostname` — your DNS name for the DataRobot UI

> Quick check that the WI annotation is non-empty before you install —
> a forgotten paste here is the most common cause of "pods come up but
> can't read GCS":
> ```bash
> grep "iam.gke.io/gcp-service-account" kubernetes/values-poc.yaml
> ```

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

## Troubleshooting

### `Quota 'SSD_TOTAL_GB' exceeded` on `terraform apply`

Default `SSD_TOTAL_GB` quota in a fresh GCP project is **500 GB per
region**. **Important:** `pd-ssd`, `pd-balanced`, and `pd-extreme` all
count against this same quota — only `pd-standard` is exempt. Don't
assume "balanced" gives you a separate budget; it doesn't.

This stack mitigates by:
- defaulting worker boot disks to `pd-standard` (`var.worker_disk_type`),
- constraining the temporary default pool that GKE creates during cluster
  bootstrap to `e2-small` + 20 GB `pd-standard`,
- reserving the SSD quota for the chart's hot-path PVCs (Postgres, Mongo,
  ES, Redis ≈ 160 GB combined) on the `datarobot-ssd` StorageClass.

**Check for orphaned disks first** — a previous failed apply often
leaves SSD disks behind that still consume quota:

```bash
gcloud compute disks list --project="$PROJECT_ID" \
  --filter="zone:us-central1 AND (type~pd-ssd OR type~pd-balanced)" \
  --format="table(name,sizeGb,type.basename(),zone.basename(),users.basename())"

# Delete unattached ones (the users column is empty):
gcloud compute disks delete <DISK_NAME> --zone=us-central1-a --quiet
```

If you still need more headroom, request a quota bump:

```bash
# Inspect current usage and limit
gcloud compute regions describe "$REGION" \
  --format="value(quotas)" | tr ',' '\n' | grep -i ssd

# Request 2 TB (UI: IAM & Admin → Quotas → filter "SSD")
# Or via gcloud:
gcloud alpha services quota update \
  --service=compute.googleapis.com \
  --consumer="projects/$PROJECT_ID" \
  --metric=compute.googleapis.com/ssd_total_storage \
  --value=2048 \
  --unit=1/{project}/{region} \
  --dimensions=region=$REGION
```

Quota increases under 2 TB usually auto-approve in a few minutes. After
approval, re-run `terraform apply`.

### Spot capacity unavailable

If the autoscaler can't get spot `n2-highmem-16` capacity in
`us-central1-a`, either widen `node_locations` to all three zones or set
`-var worker_use_spot=false`.

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
