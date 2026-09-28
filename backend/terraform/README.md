# CloudArena Infrastructure as Code

This directory contains the Terraform configuration to provision the entire GCP infrastructure for CloudArena.

## Managed Resources

- **Google Cloud Run (v2)**
  - `game_server`: WebSocket backend, autoscaling (1 to 10 instances).
  - `matchmaking_api`: REST API, autoscaling (1 to 5 instances).
- **Google Cloud Memorystore (Redis)**: Centralized state sync and leaderboards.
- **Google Compute Engine (VPC)**: Custom VPC for Redis and Serverless VPC Access.
- **Google Artifact Registry**: Docker repository for Cloud Run images.
- **IAM**: Public unauthenticated access for Cloud Run services.

## Prerequisites

1. Install [Terraform](https://developer.hashicorp.com/terraform/downloads) (v1.5.0+).
2. Install the [Google Cloud CLI (`gcloud`)](https://cloud.google.com/sdk/docs/install).
3. Authenticate with Google Cloud and configure Application Default Credentials (ADC):
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```
4. Ensure billing is enabled for your Google Cloud Project.

## Usage

1. **Configure Variables**
   Copy the example variables file and set your project ID:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars and add your GCP Project ID
   ```

2. **Initialize Terraform**
   ```bash
   terraform init
   ```

3. **Plan the Deployment**
   Review what Terraform will create:
   ```bash
   terraform plan
   ```

4. **Apply the Configuration**
   Deploy the infrastructure:
   ```bash
   terraform apply
   ```

## Deployment Flow with Terraform

Terraform manages the infrastructure, but you still need to build and push the Docker images for Cloud Run. 
Because Terraform references the Docker images in Artifact Registry, the typical initial flow is:

1. **Create the Artifact Registry repo first** (can be done by commenting out the Cloud Run services in `main.tf` and running `terraform apply`, or running the first step of `deploy_cloudrun.sh`).
2. **Build and push the Docker images** using `deploy_cloudrun.sh`.
3. **Run `terraform apply`** to deploy the full infrastructure including Redis, VPC connector, and Cloud Run services.

## Outputs

After a successful `terraform apply`, you will see outputs like:
- `game_server_websocket_url`: The URL to put in your Godot client.
- `matchmaking_api_url`: The URL for the REST API.
- `redis_host`: The internal IP of the Redis instance.
