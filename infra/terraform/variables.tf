variable "edp_project_id" {
  description = "Project that holds BigQuery claims and the anomaly dataset (VPC 1)"
  type        = string
}

variable "app_project_id" {
  description = "Project that runs the web app on GKE (VPC 2)"
  type        = string
}

variable "region" {
  description = "Region for Cloud SQL, Redis and the GKE workloads"
  type        = string
  default     = "us-central1"
}

variable "bq_location" {
  description = "BigQuery location of the claims dataset"
  type        = string
  default     = "US"
}

variable "claims_dataset_id" {
  description = "Existing dataset that holds the claims table"
  type        = string
  default     = "edp"
}

variable "app_network_id" {
  description = "Self link or id of the VPC 2 network, e.g. projects/app-project/global/networks/app-vpc"
  type        = string
}

variable "psc_ip" {
  description = "Internal IP for the Private Service Connect endpoint for Google APIs (not in any subnet range)"
  type        = string
  default     = "10.255.0.5"
}

variable "psc_endpoint_name" {
  description = "PSC endpoint name: 1-20 lowercase letters and digits, starting with a letter"
  type        = string
  default     = "pscgoogleapis"
}

variable "use_vpc_sc_bundle" {
  description = "Use the vpc-sc API bundle (true when the EDP project is inside a VPC Service Controls perimeter)"
  type        = bool
  default     = true
}

variable "k8s_namespace" {
  description = "Kubernetes namespace of the web app"
  type        = string
  default     = "anomaly"
}

variable "create_cloudsql" {
  description = "Create the Cloud SQL instance for review state. Requires private services access on the VPC 2 network."
  type        = bool
  default     = true
}

variable "create_redis" {
  description = "Create the Memorystore Redis instance. Requires private services access on the VPC 2 network."
  type        = bool
  default     = true
}
