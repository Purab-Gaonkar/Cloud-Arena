output "game_server_url" {
  description = "The URL of the Game Server Cloud Run service"
  value       = google_cloud_run_v2_service.game_server.uri
}

output "game_server_websocket_url" {
  description = "The WebSocket URL of the Game Server to configure in Godot clients"
  value       = replace(google_cloud_run_v2_service.game_server.uri, "https://", "wss://")
}

output "matchmaking_api_url" {
  description = "The URL of the Matchmaking API Cloud Run service"
  value       = google_cloud_run_v2_service.matchmaking_api.uri
}

output "redis_host" {
  description = "The IP address of the Memorystore Redis instance"
  value       = google_redis_instance.redis.host
}

output "artifact_registry_repo" {
  description = "The Artifact Registry repository name"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}"
}
