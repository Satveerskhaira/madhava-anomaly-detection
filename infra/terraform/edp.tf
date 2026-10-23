# VPC 1 / EDP project: anomaly dataset, scheduled queries, run-complete topic.
# Tables are created by sql/bigquery/ddl/001_edp_anomaly_tables.sql (run once after apply).

data "google_project" "edp" {
  project_id = var.edp_project_id
}

resource "google_bigquery_dataset" "edp_anomaly" {
  project     = var.edp_project_id
  dataset_id  = "edp_anomaly"
  location    = var.bq_location
  description = "Z-score anomaly detection: baselines, results and flagged transactions"
}

resource "google_service_account" "zscore_job" {
  project      = var.edp_project_id
  account_id   = "sa-zscore-job"
  display_name = "Anomaly z-score scheduled queries"
}

# Read claims, write the anomaly dataset, run query jobs in the EDP project.
resource "google_bigquery_dataset_iam_member" "zscore_reads_claims" {
  project    = var.edp_project_id
  dataset_id = var.claims_dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.zscore_job.email}"
}

resource "google_bigquery_dataset_iam_member" "zscore_writes_anomaly" {
  project    = var.edp_project_id
  dataset_id = google_bigquery_dataset.edp_anomaly.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.zscore_job.email}"
}

resource "google_project_iam_member" "zscore_job_user" {
  project = var.edp_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.zscore_job.email}"
}

locals {
  dts_service_agent = "service-${data.google_project.edp.number}@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com"
}

# The BigQuery Data Transfer service agent runs scheduled queries as sa-zscore-job.
resource "google_service_account_iam_member" "dts_can_use_zscore_sa" {
  service_account_id = google_service_account.zscore_job.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.dts_service_agent}"
}

resource "google_pubsub_topic" "run_complete" {
  project = var.edp_project_id
  name    = "anomaly-run-complete"
}

# Scheduled query run notifications are published by the transfer service agent.
resource "google_pubsub_topic_iam_member" "dts_publishes_run_complete" {
  project = var.edp_project_id
  topic   = google_pubsub_topic.run_complete.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.dts_service_agent}"
}

locals {
  sql_root = "${path.module}/../../sql/bigquery/jobs"
}

resource "google_bigquery_data_transfer_config" "daily_baselines" {
  project              = var.edp_project_id
  display_name         = "anomaly-daily-baselines"
  location             = var.bq_location
  data_source_id       = "scheduled_query"
  schedule             = "every day 01:30"
  service_account_name = google_service_account.zscore_job.email

  params = {
    query = replace(file("${local.sql_root}/010_daily_baselines.sql"), "edp-project", var.edp_project_id)
  }

  email_preferences {
    enable_failure_email = true
  }
}

resource "google_bigquery_data_transfer_config" "zscore_every_2h" {
  project                   = var.edp_project_id
  display_name              = "anomaly-zscore-every-2h"
  location                  = var.bq_location
  data_source_id            = "scheduled_query"
  schedule                  = "every 2 hours from 00:20 to 22:20"
  service_account_name      = google_service_account.zscore_job.email
  notification_pubsub_topic = google_pubsub_topic.run_complete.id

  params = {
    query = replace(file("${local.sql_root}/020_zscore_every_2h.sql"), "edp-project", var.edp_project_id)
  }

  email_preferences {
    enable_failure_email = true
  }

  depends_on = [google_pubsub_topic_iam_member.dts_publishes_run_complete]
}
