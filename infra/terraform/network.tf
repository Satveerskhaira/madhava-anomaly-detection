# VPC 2: Private Service Connect endpoint for Google APIs, plus private DNS so that
# bigquery.googleapis.com, bigquerystorage.googleapis.com and pubsub.googleapis.com
# resolve to the endpoint. No VPC peering with VPC 1 is needed.

resource "google_compute_global_address" "psc_googleapis" {
  project      = var.app_project_id
  name         = "psc-googleapis-ip"
  purpose      = "PRIVATE_SERVICE_CONNECT"
  address_type = "INTERNAL"
  network      = var.app_network_id
  address      = var.psc_ip
}

resource "google_compute_global_forwarding_rule" "psc_googleapis" {
  project               = var.app_project_id
  name                  = var.psc_endpoint_name
  target                = var.use_vpc_sc_bundle ? "vpc-sc" : "all-apis"
  network               = var.app_network_id
  ip_address            = google_compute_global_address.psc_googleapis.id
  load_balancing_scheme = ""
}

resource "google_dns_managed_zone" "googleapis" {
  project     = var.app_project_id
  name        = "googleapis-psc"
  dns_name    = "googleapis.com."
  visibility  = "private"
  description = "Send Google API traffic from VPC 2 to the PSC endpoint"

  private_visibility_config {
    networks {
      network_url = var.app_network_id
    }
  }
}

resource "google_dns_record_set" "googleapis_apex" {
  project      = var.app_project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = [var.psc_ip]
}

resource "google_dns_record_set" "googleapis_wildcard" {
  project      = var.app_project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "*.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = [var.psc_ip]
}
