variable "project_id" {
  description = "GCP project ID for the DataRobot PoC."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources (VPC subnet, GKE control plane, GCS multi-region pinned bucket location)."
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "Zones used by the regional GKE cluster node pools. Note: a regional GKE cluster always replicates the control plane across 3 zones; this variable is informational for documentation only."
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b", "us-central1-c"]
}

variable "node_locations" {
  description = "Zones the node pools actually run in. For a few-day PoC, pin to a single zone to cut node count by 3x."
  type        = list(string)
  default     = ["us-central1-a"]
}

variable "name_prefix" {
  description = "Prefix applied to all named resources to keep the PoC isolated."
  type        = string
  default     = "datarobot-poc"
}

# ---------- Networking ----------

variable "subnet_cidr" {
  description = "Primary CIDR for the GKE node subnet."
  type        = string
  default     = "10.20.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range CIDR for GKE Pods (VPC-native / alias IPs)."
  type        = string
  default     = "10.40.0.0/14"
}

variable "services_cidr" {
  description = "Secondary range CIDR for GKE Services."
  type        = string
  default     = "10.24.0.0/20"
}

variable "master_ipv4_cidr_block" {
  description = "RFC1918 /28 reserved for the GKE control plane."
  type        = string
  default     = "172.16.0.0/28"
}

variable "master_authorized_cidrs" {
  description = "CIDR blocks allowed to reach the public control plane endpoint. Lock this down in production."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [
    {
      cidr_block   = "0.0.0.0/0"
      display_name = "open-poc-only-replace-me"
    }
  ]
}

# ---------- GKE node pools ----------

variable "kubernetes_version" {
  description = "GKE master/min node version. Leave null to use the channel default."
  type        = string
  default     = null
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
  default     = "REGULAR"
}

variable "system_machine_type" {
  description = "Machine type for the system/default node pool. PoC default is e2-standard-2 (2 vCPU / 8 GiB) -- enough for kube-system, ingress, cert-manager."
  type        = string
  default     = "e2-standard-2"
}

variable "system_node_count" {
  description = "Per-zone node count for the system pool. 1 per zone x 3 zones = 3 nodes for HA of system add-ons."
  type        = number
  default     = 1
}

variable "worker_machine_type" {
  description = "Machine type for the DataRobot modeling worker pool. n2-highmem-16 (16 vCPU / 128 GiB) matches DataRobot's documented sizing for real modeling workloads."
  type        = string
  default     = "n2-highmem-16"
}

variable "worker_min_count" {
  description = "Minimum nodes per zone in the modeling worker pool. 1 keeps one warm worker so the first job doesn't wait on node provisioning."
  type        = number
  default     = 1
}

variable "worker_max_count" {
  description = "Maximum nodes per zone in the modeling worker pool. Cluster autoscaler will scale within this bound."
  type        = number
  default     = 3
}

variable "worker_disk_size_gb" {
  description = "Boot disk size for worker nodes."
  type        = number
  default     = 100
}

variable "worker_disk_type" {
  description = "Boot disk type for worker nodes. pd-balanced uses a separate, larger quota than pd-ssd and is fast enough for boot + container layers; pd-ssd PVCs (StorageClass datarobot-ssd) still serve hot data paths."
  type        = string
  default     = "pd-balanced"
}

variable "worker_use_spot" {
  description = "Use Spot VMs for the modeling worker pool. ~60-91% cheaper but preemptible. True is correct for a short-lived PoC; set false for production."
  type        = bool
  default     = true
}

# ---------- Storage ----------

variable "blob_buckets" {
  description = "Logical name suffixes for the GCS buckets DataRobot uses for blob storage (e.g. file-storage, model-artifacts)."
  type        = list(string)
  default     = ["file-storage", "model-artifacts", "prediction-data"]
}
