terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
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

# ── Cloud Run: Game Server ────────────────────────────────────────────────────
resource "google_cloud_run_v2_service" "game_server" {
  name     = "cloud-arena-game-server"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    scaling {
      max_instance_count = 10
      min_instance_count = 1
    }
    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "PRIVATE_RANGES_ONLY"
    }
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}/game-server:latest"
      
      ports {
        name           = "h2c" # WebSocket requires HTTP/2 cleartext in Cloud Run
        container_port = 8765
      }

      env {
        name  = "REDIS_URL"
        value = "redis://${google_redis_instance.redis.host}:${google_redis_instance.redis.port}"
      }
      env {
        name  = "PORT"
        value = "8765"
      }
      env {
        name  = "HEALTH_PORT"
        value = "8766"
      }
      env {
        name  = "MAX_ROOMS"
        value = "50"
      }
      env {
        name  = "MAX_PLAYERS_ROOM"
        value = "4"
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # CPU must be always allocated for WebSockets
        cpu_idle = false 
      }

      liveness_probe {
        http_get {
          path = "/health"
          port = 8766
        }
        initial_delay_seconds = 10
        period_seconds        = 30
      }
      
      startup_probe {
        http_get {
          path = "/health"
          port = 8766
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 6
      }
    }
    
    timeout = "3600s" # Long timeout for persistent WebSocket connections
    max_instance_request_concurrency = 100
  }

  depends_on = [google_project_service.run]
  
  # Ignore image changes to avoid Terraform reverting deployments done via CI/CD
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image
    ]
  }
}

# Allow public unauthenticated access to Game Server
resource "google_cloud_run_v2_service_iam_member" "game_server_public" {
  project  = google_cloud_run_v2_service.game_server.project
  location = google_cloud_run_v2_service.game_server.location
  name     = google_cloud_run_v2_service.game_server.name
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
      max_instance_count = 5
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
        name  = "GAME_SERVER_WS_HOST"
        # Extract hostname from the game server URI and format as wss://
        value = replace(google_cloud_run_v2_service.game_server.uri, "https://", "wss://")
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
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
    
    timeout = "30s"
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
