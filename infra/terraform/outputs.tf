output "zscore_job_service_account" {
  value = google_service_account.zscore_job.email
}

output "anomaly_api_service_account" {
  value = google_service_account.anomaly_api.email
}

output "notifier_service_account" {
  value = google_service_account.notifier.email
}

output "run_complete_topic" {
  value = google_pubsub_topic.run_complete.id
}

output "run_complete_subscription" {
  value = google_pubsub_subscription.run_complete_app.id
}

output "psc_endpoint_ip" {
  value = google_compute_global_address.psc_googleapis.address
}

output "cloudsql_instance_connection_name" {
  value = var.create_cloudsql ? google_sql_database_instance.reviews[0].connection_name : null
}

output "redis_host" {
  value = var.create_redis ? google_redis_instance.cache[0].host : null
}
