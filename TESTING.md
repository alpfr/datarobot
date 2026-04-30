# Testing the DataRobot PoC

Five layers of testing, ordered from cheapest to most expensive — stop at
the first one that fails and fix it before moving on.

1. [Cluster health](#1-cluster-health)
2. [Workload Identity is actually working](#2-workload-identity-is-actually-working)
3. [Chart install health](#3-chart-install-health)
4. [UI smoke test](#4-ui-smoke-test)
5. [End-to-end ML smoke test](#5-end-to-end-ml-smoke-test)

---

## 1. Cluster health

```bash
# Both pools should show one node each (system, modeling)
kubectl get nodes -o wide --show-labels | grep -E "pool|NAME"

# StorageClass present and default-claimable
kubectl get storageclass datarobot-ssd

# Workload Identity webhook is running (mandatory for the chart's KSA to mint tokens)
kubectl -n kube-system get pods -l k8s-app=gke-metadata-server

# Quick scheduling test on the modeling pool — must tolerate the taint
kubectl run wi-probe --rm -it --restart=Never \
  --image=google/cloud-sdk:slim \
  --overrides='{"spec":{"nodeSelector":{"pool":"modeling"},"tolerations":[{"key":"workload","operator":"Equal","value":"datarobot","effect":"NoSchedule"}]}}' \
  -- bash -c "echo OK on \$(hostname)"
```

If `wi-probe` lands and prints OK, the modeling pool is healthy and the
toleration in `values-poc.yaml` matches the taint.

## 2. Workload Identity is actually working

Most "the chart installs but DataRobot can't read GCS" failures live here.
Test the Workload Identity exchange before installing the chart, using a
throwaway pod under the *exact* KSA the chart will create.

```bash
# Create the KSA up front with the same name and annotation the chart uses
kubectl -n datarobot create serviceaccount datarobot-app
kubectl -n datarobot annotate serviceaccount datarobot-app \
  iam.gke.io/gcp-service-account=datarobot-poc-app@alpfr-splunk-integration.iam.gserviceaccount.com

# Run a probe pod under that KSA on the modeling pool
kubectl -n datarobot run gcs-probe --rm -it --restart=Never \
  --image=google/cloud-sdk:slim \
  --serviceaccount=datarobot-app \
  --overrides='{"spec":{"nodeSelector":{"pool":"modeling"},"tolerations":[{"key":"workload","operator":"Equal","value":"datarobot","effect":"NoSchedule"}]}}' \
  -- bash -c '
      set -e
      echo "Active identity:"; gcloud auth list 2>/dev/null
      echo
      echo "List PoC buckets:"
      gcloud storage ls "gs://alpfr-splunk-integration-datarobot-poc-file-storage" || echo "(empty)"
      echo
      echo "Round-trip object write/read:"
      echo "hello" > /tmp/h
      gcloud storage cp /tmp/h "gs://alpfr-splunk-integration-datarobot-poc-file-storage/wi-probe.txt"
      gcloud storage cat "gs://alpfr-splunk-integration-datarobot-poc-file-storage/wi-probe.txt"
      gcloud storage rm  "gs://alpfr-splunk-integration-datarobot-poc-file-storage/wi-probe.txt"
'
```

Expected: `Active identity` shows
`datarobot-poc-app@alpfr-splunk-integration.iam.gserviceaccount.com`,
the bucket lists, and the round-trip prints `hello`. If you see a 401 or
"anonymous caller", the KSA annotation or the
`google_service_account_iam_member.workload_identity_binding` binding in
Terraform is wrong — fix that before installing.

## 3. Chart install health

Run after `helm upgrade --install datarobot …`.

```bash
# Watch rollout (should converge in 10–20 min on PoC sizing)
kubectl -n datarobot get pods -w

# Once stable: every Pod should be Running/Ready and 0 CrashLoopBackOff
kubectl -n datarobot get pods -o wide | grep -vE "Running|Completed" || echo "all healthy"

# StatefulSet PVCs bound to datarobot-ssd
kubectl -n datarobot get pvc \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,SC:.spec.storageClassName,SIZE:.spec.resources.requests.storage

# Ingress has an external IP and the LB is healthy
kubectl -n datarobot get ingress
gcloud compute forwarding-rules list --project=alpfr-splunk-integration \
  --format="table(name,IPAddress,target.basename())"

# Anything weird in events lately?
kubectl -n datarobot get events --sort-by=.lastTimestamp | tail -20
```

Common gotchas to look for:

| Symptom | Likely cause |
|---|---|
| Postgres/Mongo Pod `Pending`, `0/X nodes available: had volume node affinity conflict` | StorageClass binding mode mismatch — should be `WaitForFirstConsumer` |
| App pods `CrashLoopBackOff` with 401 to `*.googleapis.com` | Workload Identity not wired (re-run the §2 probe) |
| `ImagePullBackOff` | `imagePullSecrets` missing or wrong registry hostname |
| Ingress IP stuck `<pending>` for >5 min | Backend service not ready yet, or a quota issue on `BACKEND_SERVICES` |

## 4. UI smoke test

```bash
# Resolve the LB IP and point your DNS at it (or /etc/hosts for a quick test):
LB_IP=$(kubectl -n datarobot get ingress \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
echo "$LB_IP  datarobot.example.com" | sudo tee -a /etc/hosts
```

1. Browse to `https://datarobot.example.com`. The page should serve over
   TLS (cert from cert-manager or your manual Secret).
2. Log in with the bootstrap admin credentials your DataRobot SA gave
   you, change the password.
3. Confirm the *About* / *System Status* page reports a license that
   matches the one you uploaded.
4. Upload `iris.csv` (any tiny CSV will do) via the UI. The file should
   land in the `*-file-storage` bucket — verify:
   ```bash
   gcloud storage ls -r "gs://alpfr-splunk-integration-datarobot-poc-file-storage"
   ```

## 5. End-to-end ML smoke test

Train a model and score one row. Tiny dataset; finishes in a few minutes
on the PoC worker.

### Option A — UI

1. *New Project* → upload `iris.csv` (or any small classification CSV).
2. Pick the target column → *Quick Autopilot* → start.
3. Wait for the leaderboard to populate (you'll see the modeling pool
   auto-scale up if Autopilot needs more capacity).
4. *Predict* → upload a 5-row holdout CSV → confirm predictions return.

### Option B — API (faster to script, easier to put in CI later)

```bash
pip install datarobot

python - <<'PY'
import os, datarobot as dr
dr.Client(
    endpoint="https://datarobot.example.com/api/v2",
    token=os.environ["DR_API_TOKEN"],   # generate one in UI > Developer Tools
    ssl_verify=False,                   # only if you're using a self-signed cert
)

proj = dr.Project.create("https://archive.ics.uci.edu/ml/machine-learning-databases/iris/iris.data",
                         project_name="poc-smoke")
proj.set_target(target="class", mode=dr.AUTOPILOT_MODE.QUICK)
proj.wait_for_autopilot()

best = proj.get_models()[0]
print("best model:", best.model_type, "auc:", best.metrics.get("AUC"))
PY
```

If the script returns a model + metric, the full stack is healthy:
ingestion → Postgres/Mongo metadata → modeling pool compute →
GCS artifact storage → API serving.

### Cleanup probe artifacts

```bash
kubectl -n datarobot delete pod gcs-probe --ignore-not-found
gcloud storage rm "gs://alpfr-splunk-integration-datarobot-poc-file-storage/wi-probe.txt" 2>/dev/null || true
```

---

**When all five layers pass, the PoC is real.** Save a screenshot of the
leaderboard for your write-up, then `terraform destroy` to stop the
billing meter.
