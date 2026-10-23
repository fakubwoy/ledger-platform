variable "subscription_id" {
  type        = string
  description = "Azure subscription to deploy into"
}

variable "location" {
  type    = string
  default = "centralindia"
}

variable "prefix" {
  type    = string
  default = "ledger"
}

variable "node_size" {
  type        = string
  default     = "Standard_B2s_v2"
  description = "2 vCPU / 8 GB: enough for the ledger, Strimzi and Kafka at dev scale"
}
