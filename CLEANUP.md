# Cleanup / Teardown

Order matters. Helm release first, then Kubernetes leftovers, then
Terraform — otherwise `terraform destroy` will hang or fail trying to
delete a subnet that still has an LB forwarding rule attached.

After everything below runs clean, verify the billing meter is at zero
with the [final check](#5-final-bill-check).

---

## 1. Uninstall the Helm release

```bash
helm -n datarobot uninstall datarobot

# Wait for chart-managed pods to terminate
kubectl -n datarobot get pods -w
# Ctrl-C once the namespace is empty
```

## 2. Delete Kubernetes leftovers Helm doesn't own

The chart leaves these behind by design:

```bash
# PersistentVolumeClaims (and their backing pd-ssd disks)
kubectl -n datarobot get pvc
kubectl -n datarobot delete pvc --all

# LoadBalancer services / Ingresses (these create GCP forwarding rules
# that block VPC + subnet deletion)
kubectl -n datarobot get svc,ingress
kubectl -n datarobot delete ingress --all
kubectl -n datarobot delete svc -l app.kubernetes.io/instance=datarobot

# Secrets you created manually
kubectl -n datarobot delete secret datarobot-license datarobot-regcred datarobot-tls --ignore-not-found

# Finally, the namespace itself
kubectl delete namespace datarobot
```

Confirm no stranded GCP load-balancer resources before continuing — these
are the #1 cause of `terraform destroy` failures:

```bash
gcloud compute forwarding-rules list --project=alpfr-splunk-integration \
  --format="table(name,region.basename(),IPAddress,target.basename())"

gcloud compute backend-services list --project=alpfr-splunk-integration \
  --format="table(name,region.basename())"

gcloud compute target-pools list --project=alpfr-splunk-integration \
  --format="table(name,region.basename())"
```

If any of those show `datarobot-*` rows, delete them by name:

```bash
gcloud compute forwarding-rules delete <NAME> --region=us-east1 --quiet
gcloud compute backend-services delete <NAME> --region=us-east1 --quiet
```

## 3. Terraform destroy

```bash
cd /Users/alpfr/Downloads/scripts/datarobot/terraform

terraform destroy -auto-approve \
  -var "project_id=alpfr-splunk-integration"
```

Expected: `Destroy complete! Resources: 28 destroyed.`

Bucket contents are removed automatically because we set
`force_destroy = true` for the PoC. The buckets themselves disappear
with the rest of the stack.

## 4. Hunt for orphans

GCP's failure modes leave things behind even after Terraform claims it
destroyed everything. Run all four:

```bash
PROJECT="alpfr-splunk-integration"
REGION="us-east1"

# 4a. Persistent disks (especially pd-ssd — these silently eat your quota)
gcloud compute disks list --project="$PROJECT" \
  --filter="zone:$REGION" \
  --format="table(name,sizeGb,type.basename(),zone.basename(),users.basename())"

# 4b. Static / reserved external addresses
gcloud compute addresses list --project="$PROJECT" \
  --filter="region:$REGION" \
  --format="table(name,address,addressType,status,users.basename())"

# 4c. Firewall rules auto-created by GKE (named gke-*)
gcloud compute firewall-rules list --project="$PROJECT" \
  --filter="name~gke-datarobot-poc" \
  --format="table(name,network.basename(),sourceRanges,targetTags)"

# 4d. GCS buckets (should be gone, but double-check)
gcloud storage buckets list --project="$PROJECT" \
  --filter="name~datarobot-poc"
```

Delete anything that shows up:

```bash
gcloud compute disks delete <NAME>          --zone=us-east1-b --quiet
gcloud compute addresses delete <NAME>      --region=us-east1 --quiet
gcloud compute firewall-rules delete <NAME> --quiet
gcloud storage rm --recursive "gs://<BUCKET_NAME>"
```

## 5. Final bill check

Two ways to confirm nothing is still costing you money:

```bash
# Billing console URL (paste into a browser)
echo "https://console.cloud.google.com/billing/projects/$PROJECT_ID/cost"

# Anything in the project that bills by the hour
gcloud compute instances list --project="$PROJECT" 2>&1
gcloud container clusters list --project="$PROJECT" 2>&1
gcloud compute forwarding-rules list --project="$PROJECT" 2>&1
```

All three should print `Listed 0 items.` (or only show resources from
*other* projects/clusters you intend to keep, like `opssightai`).

## 6. Optional: kill the local artifacts too

```bash
# Local Terraform state (only do this AFTER you've confirmed destroy succeeded)
rm -rf /Users/alpfr/Downloads/scripts/datarobot/terraform/.terraform
rm -f  /Users/alpfr/Downloads/scripts/datarobot/terraform/terraform.tfstate*

# kubectl context for the now-deleted cluster
kubectl config delete-context $(kubectl config current-context) 2>/dev/null || true
kubectl config delete-cluster gke_${PROJECT}_us-east1_datarobot-poc-gke 2>/dev/null || true

# Helm repo cache
helm repo remove datarobot 2>/dev/null || true
```

The repo on disk and on GitHub stays — it's just config, no secrets.

---

## If `terraform destroy` fails

The two failure modes you'll actually hit:

### "The resource is in use by another resource"

Almost always a stranded LB forwarding rule from the chart's Ingress.
Re-run §2's `gcloud compute forwarding-rules list` and delete by name,
then `terraform destroy` again.

### "Service account in use" / "Cannot delete service account"

Usually the GKE cluster wasn't fully torn down. Force-delete via:

```bash
gcloud container clusters delete datarobot-poc-gke \
  --region=us-east1 --project="$PROJECT" --quiet

terraform state rm google_container_cluster.primary
terraform state rm google_container_node_pool.system
terraform state rm google_container_node_pool.workers
terraform destroy -auto-approve -var "project_id=$PROJECT"
```

---

## Disabling APIs (paranoid mode)

The Terraform stack enables several APIs but `disable_on_destroy` is set
to `false` (disabling APIs can break unrelated workloads in the same
project). If you want them disabled anyway and you're sure nothing else
in the project depends on them:

```bash
for api in compute container iam iamcredentials storage logging monitoring; do
  gcloud services disable "${api}.googleapis.com" \
    --project="$PROJECT" --force
done
```

`--force` is required because GCP refuses to disable APIs that other
services in the project still depend on.
