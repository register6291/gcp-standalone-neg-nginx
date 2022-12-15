locals {
  negs = [for zone in var.zones :
  "https://www.googleapis.com/compute/v1/projects/${var.project_id}/zones/${zone}/networkEndpointGroups/ingress-nginx-controller-neg"]
}