# Values come from terraform.tfvars locally (git-ignored) and TF_VAR_* in CI.

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

variable "vnet_address_space" {
  description = "Address range of the virtual network"
  type        = string
  default     = "10.10.0.0/16"
}

variable "apps_subnet_prefix" {
  description = "Subnet for Container Apps (Consumption environments need at least a /23)"
  type        = string
  default     = "10.10.0.0/23"
}

variable "data_subnet_prefix" {
  description = "Subnet for the Postgres private endpoint"
  type        = string
  default     = "10.10.2.0/27"
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
  description = "Azure region for PostgreSQL. Keep it equal to location (latency, cost). Change only if Azure rejects the region for your subscription."
  type        = string
  default     = "eastus"
}

variable "alert_email" {
  description = "Where alerts and budget warnings are emailed"
  type        = string
}

variable "monthly_budget" {
  description = "Monthly spend limit in USD for the resource group"
  type        = number
  default     = 25
}
