variable "project" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "zone" {
  type    = string
  default = "asia-south1-a"
}

variable "prefix" {
  type    = string
  default = "ledger"
}

variable "machine_type" {
  type        = string
  default     = "e2-standard-2"
  description = "2 vCPU / 8 GB: enough for the ledger, Strimzi and Kafka at dev scale"
}
