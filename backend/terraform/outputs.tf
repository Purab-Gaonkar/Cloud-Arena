output "game_host_urls" {
  description = "WebSocket base URL of every game host (clients receive these from the matchmaking API)"
  value       = local.game_host_urls
}

output "matchmaking_api_url" {
  description = "Base URL to enter in the game's ONLINE menu"
  value       = google_cloud_run_v2_service.matchmaking_api.uri
}

output "redis_host" {
  description = "The IP address of the Memorystore Redis instance"
  value       = google_redis_instance.redis.host
}

output "artifact_registry_repo" {
  description = "Artifact Registry repository (push the game-server and matchmaking-api images here)"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}"
}
