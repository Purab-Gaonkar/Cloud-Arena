variable "project_id" {
  description = "The GCP Project ID where the infrastructure will be deployed"
  type        = string
}

variable "region" {
  description = "The GCP region for the resources (e.g., us-central1)"
  type        = string
  default     = "us-central1"
}
