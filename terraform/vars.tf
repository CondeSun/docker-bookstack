variable "azure-subscription-id" {
  type = string
  description = "Valid Azure Subscription ID"
}

variable "azure-tenant_id" {
  type = string
  description = "Vaild Azure Tenant ID"
}

variable "bookstack-db-name" {
  type = string
  description = "Mysql Bookstack database name"
}

variable "bookstack-db-user" {
  type = string
  description = "Mysql Bookstack database user"
}

variable "bookstack-db-password" {
  type = string
  description = "Mysql Bookstack database password"
}

variable "bookstack-db-root-pw" {
  type = string
  description = "Mysql root password"
}
