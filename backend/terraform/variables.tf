variable "project_id" {
  description = "The GCP Project ID where the infrastructure will be deployed"
  type        = string
}

variable "region" {
  description = "The GCP region for the resources (default asia-south1 = Mumbai)"
  type        = string
  default     = "asia-south1"
}

variable "game_host_count" {
  description = "Maximum number of game host services. Host 1 is always on, the rest scale to zero and are started on demand (each runs up to var.rooms_per_host matches at once)"
  type        = number
  default     = 3
}

variable "rooms_per_host" {
  description = "Maximum concurrent matches per game host (one headless Godot process each)"
  type        = number
  default     = 6
}
