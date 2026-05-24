# variables.tf

# All configurable values for the infrastructure.
# Actual values come from terraform.tfvars (never committed to Git)

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "market-pipeline"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "dev"
}

variable "db_username" {
  description = "PostgreSQL administrator username"
  type        = string
  default     = "pipeline_user"
}

variable "db_password" {
  description = "PostgreSQL administrator password"
  type        = string
  sensitive   = true
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "market_pipeline"
}

variable "local_ip" {
  description = "Your local IP for Postgres firewall rule"
  type        = string
}

variable "news_api_key" {
  description = "NewsAPI key"
  type        = string
  sensitive   = true
}

variable "dockerhub_username" {
  description = "Docker Hub username for pushing images"
  type        = string
}

variable "db_location" {
  description = "Azure region for PostgreSQL — may differ from main location"
  type        = string
  default     = "southeastasia"
}
