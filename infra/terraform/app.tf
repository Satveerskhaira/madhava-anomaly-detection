# VPC 2 / application project: service accounts, cross-project read grants,
# Pub/Sub subscription, Cloud SQL for review state, Redis cache.

resource "google_service_account" "anomaly_api" {
  project      = var.app_project_id
  account_id   = "sa-anomaly-api"
  display_name = "Anomaly API (BigQuery JDBC reads, review state)"
}

resource "google_service_account" "notifier" {
  project      = var.app_project_id
  account_id   = "sa-anomaly-notifier"
  display_name = "Run-complete notifier (Pub/Sub pull, SSE)"
}

# API reads only the anomaly dataset in EDP. It never reads edp.claims.
resource "google_bigquery_dataset_iam_member" "api_reads_anomaly" {
  project    = var.edp_project_id
  dataset_id = google_bigquery_dataset.edp_anomaly.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.anomaly_api.email}"
}

# Query jobs and Storage Read API sessions run and bill in the app project.
resource "google_project_iam_member" "api_job_user" {
  project = var.app_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.anomaly_api.email}"
}

resource "google_project_iam_member" "api_read_session_user" {
  project = var.app_project_id
  role    = "roles/bigquery.readSessionUser"
  member  = "serviceAccount:${google_service_account.anomaly_api.email}"
}

resource "google_project_iam_member" "api_cloudsql_client" {
  project = var.app_project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.anomaly_api.email}"
}

resource "google_project_iam_member" "api_cloudsql_instance_user" {
  project = var.app_project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${google_service_account.anomaly_api.email}"
}

# Subscription in the app project on the EDP topic.
# The identity running Terraform needs pubsub.topics.attachSubscription on the topic.
resource "google_pubsub_subscription" "run_complete_app" {
  project                    = var.app_project_id
  name                       = "anomaly-run-complete-app"
  topic                      = google_pubsub_topic.run_complete.id
  ack_deadline_seconds       = 60
  message_retention_duration = "86400s"

  expiration_policy {
    ttl = ""
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }
}

resource "google_pubsub_subscription_iam_member" "notifier_subscriber" {
  project      = var.app_project_id
  subscription = google_pubsub_subscription.run_complete_app.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.notifier.email}"
}

# GKE Workload Identity: Kubernetes service accounts act as the Google service accounts.
resource "google_service_account_iam_member" "api_workload_identity" {
  service_account_id = google_service_account.anomaly_api.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.app_project_id}.svc.id.goog[${var.k8s_namespace}/anomaly-api]"
}

resource "google_service_account_iam_member" "notifier_workload_identity" {
  service_account_id = google_service_account.notifier.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.app_project_id}.svc.id.goog[${var.k8s_namespace}/anomaly-notifier]"
}

# Review state. Private IP only; IAM database authentication.
resource "google_sql_database_instance" "reviews" {
  count               = var.create_cloudsql ? 1 : 0
  project             = var.app_project_id
  name                = "anomaly-reviews"
  region              = var.region
  database_version    = "POSTGRES_15"
  deletion_protection = true

  settings {
    tier              = "db-custom-2-7680"
    availability_type = "REGIONAL"

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.app_network_id
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
    }
  }
}

resource "google_sql_database" "anomaly_review" {
  count    = var.create_cloudsql ? 1 : 0
  project  = var.app_project_id
  instance = google_sql_database_instance.reviews[0].name
  name     = "anomaly_review"
}

resource "google_sql_user" "api_iam_user" {
  count    = var.create_cloudsql ? 1 : 0
  project  = var.app_project_id
  instance = google_sql_database_instance.reviews[0].name
  name     = trimsuffix(google_service_account.anomaly_api.email, ".gserviceaccount.com")
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_redis_instance" "cache" {
  count                   = var.create_redis ? 1 : 0
  project                 = var.app_project_id
  name                    = "anomaly-cache"
  region                  = var.region
  tier                    = "STANDARD_HA"
  memory_size_gb          = 1
  authorized_network      = var.app_network_id
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  transit_encryption_mode = "SERVER_AUTHENTICATION"
}
