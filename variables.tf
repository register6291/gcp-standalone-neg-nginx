variable "project_id" {
  type    = string
  default = "enduring-byte-353918"
}

variable "network" {
  type    = string
  default = "vpc-standalone-eu"
}

variable "subnetwork" {
  type    = string
  default = "subnet-standalone-eu"
}

variable "cluster_name" {
  type    = string
  default = "gke-standalone"
}

variable "zones" {
  type    = list(any)
  default = ["europe-west1-c", "europe-west1-b", "europe-west1-d"]
}