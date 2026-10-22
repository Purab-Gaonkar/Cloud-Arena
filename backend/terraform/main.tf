terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ── Enable APIs ───────────────────────────────────────────────────────────────
resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "redis" {
  service            = "redis.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "firestore" {
  service            = "firestore.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# ── Artifact Registry ─────────────────────────────────────────────────────────
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "cloud-arena"
  description   = "CloudArena Docker repository"
  format        = "DOCKER"
  depends_on    = [google_project_service.artifactregistry]
}

# ── VPC Network for Redis ─────────────────────────────────────────────────────
# Using the default network or creating a new one. We'll create a dedicated VPC.
resource "google_compute_network" "cloud_arena_vpc" {
  name                    = "cloud-arena-vpc"
  auto_create_subnetworks = true
  depends_on              = [google_project_service.compute]
}

# ── Memorystore Redis ─────────────────────────────────────────────────────────
resource "google_redis_instance" "redis" {
  name           = "cloud-arena-redis"
  tier           = "BASIC"
  memory_size_gb = 1
  region         = var.region
  redis_version  = "REDIS_7_0"

  authorized_network = google_compute_network.cloud_arena_vpc.id

  depends_on = [google_project_service.redis]
}

# ── Serverless VPC Access Connector ───────────────────────────────────────────
# Required for Cloud Run to access the private Redis instance
resource "google_project_service" "vpcaccess" {
  service            = "vpcaccess.googleapis.com"
  disable_on_destroy = false
}

resource "google_vpc_access_connector" "connector" {
  name          = "ca-connector"
  region        = var.region
  network       = google_compute_network.cloud_arena_vpc.name
  ip_cidr_range = "10.8.0.0/28"
  depends_on    = [google_project_service.vpcaccess]
}

# ── Cloud Run: Game hosts ─────────────────────────────────────────────────────
# A game host = the Python room manager + headless Godot match processes (one per room).
# Every room must be reached on the SAME instance that runs it, so each host service is capped at
# ONE instance and capacity is added by raising var.game_host_count (the matchmaking API spreads new
# rooms across hosts by load). Each host advertises its own deterministic Cloud Run URL.
data "google_project" "project" {}

locals {
  game_host_names = [for i in range(var.game_host_count) : "cloud-arena-game-${i + 1}"]
  game_host_urls  = [for n in local.game_host_names : "wss://${n}-${data.google_project.project.number}.${var.region}.run.app"]
}

resource "google_cloud_run_v2_service" "game_host" {
  count    = var.game_host_count
  name     = local.game_host_names[count.index]
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    scaling {
      max_instance_count = 1
      # The first var.game_hosts_always_on hosts stay on; the others scale to zero and are woken by the matchmaking API when needed.
      min_instance_count = count.index < var.game_hosts_always_on ? 1 : 0
    }
    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "PRIVATE_RANGES_ONLY"
    }
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}/game-server:latest"

      ports {
        container_port = 8765
      }

      env {
        name  = "REDIS_URL"
        value = "redis://${google_redis_instance.redis.host}:${google_redis_instance.redis.port}"
      }
      env {
        name  = "SERVER_ID"
        value = local.game_host_names[count.index]
      }
      env {
        name  = "PUBLIC_WS_BASE"
        value = local.game_host_urls[count.index]
      }
      env {
        name  = "API_URL"
        value = google_cloud_run_v2_service.matchmaking_api.uri
      }
      env {
        name  = "SERVER_KEY"
        value = random_password.server_key.result
      }
      env {
        name  = "MAX_ROOMS"
        value = tostring(var.rooms_per_host)
      }

      resources {
        limits = {
          cpu    = "2"
          memory = "2Gi"
        }
        # CPU must stay allocated: matches run in background processes between requests
        cpu_idle = false
      }

      startup_probe {
        http_get {
          path = "/health"
          port = 8765
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 12
      }
      liveness_probe {
        http_get {
          path = "/health"
          port = 8765
        }
        period_seconds = 30
      }
    }

    timeout                          = "3600s" # long-lived WebSocket connections
    max_instance_request_concurrency = 200
  }

  depends_on = [google_project_service.run]

  lifecycle {
    ignore_changes = [template[0].containers[0].image]
  }
}

resource "google_cloud_run_v2_service_iam_member" "game_host_public" {
  count    = var.game_host_count
  project  = google_cloud_run_v2_service.game_host[count.index].project
  location = google_cloud_run_v2_service.game_host[count.index].location
  name     = google_cloud_run_v2_service.game_host[count.index].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ── Cloud Run: Matchmaking API ────────────────────────────────────────────────
resource "google_cloud_run_v2_service" "matchmaking_api" {
  name     = "cloud-arena-matchmaking-api"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    scaling {
      max_instance_count = 1
      min_instance_count = 1
    }
    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "PRIVATE_RANGES_ONLY"
    }
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}/matchmaking-api:latest"
      
      ports {
        container_port = 8000
      }

      env {
        name  = "REDIS_URL"
        value = "redis://${google_redis_instance.redis.host}:${google_redis_instance.redis.port}"
      }
      env {
        name  = "SERVER_KEY"
        value = random_password.server_key.result
      }
      env {
        name  = "FIRESTORE_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "GAME_HOSTS"
        value = join(",", [for i, n in local.game_host_names : "${n}=${replace(local.game_host_urls[i], "wss://", "https://")}"])
      }
      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      liveness_probe {
        http_get {
          path = "/health"
          port = 8000
        }
        initial_delay_seconds = 10
        period_seconds        = 30
      }
    }
    
    timeout = "90s"   # /match/join may wait for a game host to wake up and boot a room
    max_instance_request_concurrency = 200
  }

  depends_on = [google_project_service.run]

  # Ignore image changes
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image
    ]
  }
}

# Allow public unauthenticated access to Matchmaking API
resource "google_cloud_run_v2_service_iam_member" "matchmaking_api_public" {
  project  = google_cloud_run_v2_service.matchmaking_api.project
  location = google_cloud_run_v2_service.matchmaking_api.location
  name     = google_cloud_run_v2_service.matchmaking_api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}


# Shared secret between the game hosts and the matchmaking API (ticket redemption, match results).
resource "random_password" "server_key" {
  length  = 40
  special = false
}


# Permanent store for accounts and match history (the API writes to it after matches; Redis stays the live cache).
# Created with gcloud only if the project has no default database yet, and never deleted by terraform destroy,
# so re-applying after a destroy needs no import. Requires gcloud (preinstalled in Cloud Shell).
resource "terraform_data" "firestore" {
  input = var.project_id

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      gcloud firestore databases describe --database='(default)' --project='${var.project_id}' >/dev/null 2>&1         || gcloud firestore databases create --database='(default)' --location='${var.region}' --type=firestore-native --project='${var.project_id}'
    EOT
  }

  depends_on = [google_project_service.firestore]
}

resource "google_project_iam_member" "api_firestore" {
  depends_on = [terraform_data.firestore]
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${data.google_compute_default_service_account.default.email}"
}

data "google_compute_default_service_account" "default" {
  project    = var.project_id
  depends_on = [google_project_service.compute]
}
