output "vpc_name" {
  description = "Name of the VPC created for the PoC."
  value       = google_compute_network.vpc.name
}

output "subnet_name" {
  description = "Name of the GKE subnet."
  value       = google_compute_subnetwork.subnet.name
}

output "cluster_name" {
  description = "GKE cluster name (use with `gcloud container clusters get-credentials`)."
  value       = google_container_cluster.primary.name
}

output "cluster_location" {
  description = "Region of the GKE cluster."
  value       = google_container_cluster.primary.location
}

output "cluster_endpoint" {
  description = "Public endpoint of the GKE control plane."
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64 cluster CA cert."
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "gke_node_service_account" {
  description = "Email of the SA attached to GKE nodes."
  value       = google_service_account.gke_nodes.email
}

output "datarobot_workload_service_account" {
  description = "GCP SA the DataRobot pods impersonate via Workload Identity. Annotate the KSA with this email."
  value       = google_service_account.datarobot_app.email
}

output "blob_buckets" {
  description = "Map of logical name -> bucket name for DataRobot blob storage."
  value       = { for k, b in google_storage_bucket.blob : k => b.name }
}

output "kubectl_get_credentials_cmd" {
  description = "Convenience command to wire kubectl to this cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region ${google_container_cluster.primary.location} --project ${var.project_id}"
}
