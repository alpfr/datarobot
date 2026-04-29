terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.30"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

locals {
  vpc_name        = "${var.name_prefix}-vpc"
  subnet_name     = "${var.name_prefix}-subnet"
  router_name     = "${var.name_prefix}-router"
  nat_name        = "${var.name_prefix}-nat"
  cluster_name    = "${var.name_prefix}-gke"
  pods_range_name = "${var.name_prefix}-pods"
  svcs_range_name = "${var.name_prefix}-services"
}

# -----------------------------------------------------------------------------
# Required APIs
# -----------------------------------------------------------------------------
resource "google_project_service" "services" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# VPC + Subnet (VPC-native: secondary ranges for Pods and Services)
# -----------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = local.vpc_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.services]
}

resource "google_compute_subnetwork" "subnet" {
  name                     = local.subnet_name
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = local.pods_range_name
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = local.svcs_range_name
    ip_cidr_range = var.services_cidr
  }
}

# -----------------------------------------------------------------------------
# Cloud Router + Cloud NAT (egress for private nodes)
# -----------------------------------------------------------------------------
resource "google_compute_router" "router" {
  name    = local.router_name
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = local.nat_name
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# -----------------------------------------------------------------------------
# IAM service accounts (least privilege)
# -----------------------------------------------------------------------------

# SA used by GKE nodes. Only the minimum roles needed for kubelet + logging/monitoring.
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.name_prefix}-gke-nodes"
  display_name = "GKE node service account (DataRobot PoC)"
}

resource "google_project_iam_member" "gke_nodes_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# SA that the DataRobot workload pods will impersonate via Workload Identity.
# Bind this to a Kubernetes ServiceAccount in the DataRobot namespace via the
# `iam.workloadIdentityUser` role (see README).
resource "google_service_account" "datarobot_app" {
  account_id   = "${var.name_prefix}-app"
  display_name = "DataRobot workload SA (Workload Identity target)"
}

# -----------------------------------------------------------------------------
# GCS buckets for DataRobot blob storage
# -----------------------------------------------------------------------------
resource "google_storage_bucket" "blob" {
  for_each = toset(var.blob_buckets)

  name                        = "${var.project_id}-${var.name_prefix}-${each.value}"
  location                    = var.region
  storage_class               = "STANDARD"
  force_destroy               = true # PoC convenience; remove for prod
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age                = 30
      with_state         = "ARCHIVED"
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }
}

# Grant the DataRobot workload SA object-level access only to its buckets.
resource "google_storage_bucket_iam_member" "datarobot_app_object_admin" {
  for_each = google_storage_bucket.blob

  bucket = each.value.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.datarobot_app.email}"
}

# -----------------------------------------------------------------------------
# GKE cluster (regional, VPC-native, public endpoint, private nodes)
# -----------------------------------------------------------------------------
resource "google_container_cluster" "primary" {
  provider = google-beta

  name     = local.cluster_name
  location = var.region

  # We manage node pools ourselves; remove the default pool the API creates.
  remove_default_node_pool = true
  initial_node_count       = 1

  min_master_version = var.kubernetes_version

  release_channel {
    channel = var.release_channel
  }

  # Pin nodes to a single zone for the PoC to avoid paying for nodes in
  # all three zones of the region. The control plane is still regional.
  node_locations = var.node_locations

  network    = google_compute_network.vpc.self_link
  subnetwork = google_compute_subnetwork.subnet.self_link

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = local.pods_range_name
    services_secondary_range_name = local.svcs_range_name
  }

  # Public control plane endpoint, private nodes (no public IPs on workers).
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    horizontal_pod_autoscaling {
      disabled = false
    }
    http_load_balancing {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  deletion_protection = false

  depends_on = [
    google_project_service.services,
    google_compute_router_nat.nat,
  ]
}

# -----------------------------------------------------------------------------
# Node pool: system / default
# -----------------------------------------------------------------------------
resource "google_container_node_pool" "system" {
  name     = "system"
  location = var.region
  cluster  = google_container_cluster.primary.name

  node_count = var.system_node_count # per-zone

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.system_machine_type
    disk_size_gb = 100
    disk_type    = "pd-standard"
    image_type   = "COS_CONTAINERD"

    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      pool    = "system"
      purpose = "system"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

# -----------------------------------------------------------------------------
# Node pool: DataRobot modeling workers (autoscaling, high-memory)
# -----------------------------------------------------------------------------
resource "google_container_node_pool" "workers" {
  name     = "modeling-workers"
  location = var.region
  cluster  = google_container_cluster.primary.name

  autoscaling {
    min_node_count = var.worker_min_count # per-zone
    max_node_count = var.worker_max_count # per-zone
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.worker_machine_type
    disk_size_gb = var.worker_disk_size_gb
    disk_type    = var.worker_disk_type
    image_type   = "COS_CONTAINERD"

    # Spot VMs: ~60-91% cheaper than on-demand. May be preempted with 30s
    # notice; fine for a short-lived PoC. Flip to false for production.
    spot = var.worker_use_spot

    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      pool    = "modeling"
      purpose = "datarobot-workers"
    }

    # Taint so only DataRobot modeling pods (with matching toleration in
    # values-poc.yaml) schedule on this expensive pool.
    taint {
      key    = "workload"
      value  = "datarobot"
      effect = "NO_SCHEDULE"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

# -----------------------------------------------------------------------------
# Workload Identity binding: lets the in-cluster KSA impersonate the GCP SA.
# Replace the namespace/KSA below to match the DataRobot Helm chart values.
# -----------------------------------------------------------------------------
resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.datarobot_app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[datarobot/datarobot-app]"
}
