data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  }
}

module "gke" {
  source                     = "terraform-google-modules/kubernetes-engine/google"
  project_id                 = var.project_id
  name                       = var.cluster_name
  region                     = "europe-west1"
  zones                      = var.zones
  network                    = var.network
  subnetwork                 = var.subnetwork
  ip_range_pods              = "gke-pods"
  ip_range_services          = "gke-services"
  http_load_balancing        = true
  network_policy             = false
  horizontal_pod_autoscaling = true
  filestore_csi_driver       = false
  configure_ip_masq          = true
  remove_default_node_pool   = false
  default_max_pods_per_node  = 55
}

resource "google_compute_global_address" "load_balancer_ip" {
  project      = var.project_id
  name         = "global-loadbalancer-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

resource "google_compute_firewall" "gke_health_check_rules" {
  project       = var.project_id
  name          = "gke-health-check"
  network       = var.network
  description   = "A firewall rule to allow health check from Google Cloud to GKE"
  priority      = 1000
  direction     = "INGRESS"
  disabled      = false
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["gke-${var.cluster_name}"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

resource "helm_release" "nginx_ingress_controller" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  values     = ["${file("values.yaml")}"]
  depends_on = [module.gke]
}


resource "google_compute_health_check" "backend_service_http_health_check" {
  name                = "gke-${var.cluster_name}-backend-http-health-check"
  description         = "Health check via http"
  project             = var.project_id
  timeout_sec         = "5"
  check_interval_sec  = 60
  healthy_threshold   = 4
  unhealthy_threshold = 5

  http_health_check {
    port               = "80"
    port_specification = "USE_FIXED_PORT"
    proxy_header       = "NONE"
    request_path       = "/"
  }
  depends_on = [
    helm_release.nginx_ingress_controller
  ]
}

resource "google_compute_backend_service" "gke_backend_service" {
  affinity_cookie_ttl_sec = "0"
  name                    = "gke-${var.cluster_name}-backend-service"
  port_name               = "http"
  project                 = var.project_id
  protocol                = "HTTP"
  session_affinity        = "NONE"
  timeout_sec             = "30"
  log_config {
    enable      = "true"
    sample_rate = "1"
  }
  load_balancing_scheme           = "EXTERNAL"
  enable_cdn                      = true
  connection_draining_timeout_sec = "300"
  health_checks                   = [google_compute_health_check.backend_service_http_health_check.self_link]
  cdn_policy {
    cache_mode                   = "CACHE_ALL_STATIC"
    client_ttl                   = "3600"
    default_ttl                  = "3600"
    max_ttl                      = "86400"
    negative_caching             = "true"
    serve_while_stale            = "86400"
    signed_url_cache_max_age_sec = "0"
    cache_key_policy {
      include_host         = true
      include_protocol     = true
      include_query_string = true
    }
  }

  dynamic "backend" {
    for_each = local.negs
    content {
      balancing_mode        = "RATE"
      capacity_scaler       = "1"
      group                 = backend.value
      max_rate_per_endpoint = "1"
    }
  }
}

resource "google_compute_url_map" "url_map" {
  name    = "gke-${var.cluster_name}-url-map"
  project = var.project_id

  default_service = google_compute_backend_service.gke_backend_service.self_link
}

resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "gke-${var.cluster_name}-http-proxy"
  project = var.project_id
  url_map = google_compute_url_map.url_map.self_link
}

resource "google_compute_global_forwarding_rule" "forwarding_rule" {
  name                  = "gke-${var.cluster_name}-forwarding-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_http_proxy.http_proxy.self_link
  ip_address            = google_compute_global_address.load_balancer_ip.address
  project               = var.project_id
}
