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
  default = "bookstack"
}

variable "bookstack-db-user" {
  type = string
  description = "Mysql Bookstack database user"
  default = "bookstack"
}

variable "bookstack-db-password" {
  type = string
  description = "Mysql Bookstack database password"
  default = "thisIsAVerySecureMysqlNonProdSecret"
}

variable "bookstack-db-root-pw" {
  type = string
  description = "Mysql root password"
  default = "thisIsAVerySecureMysqlNonProdSecret"
}

// will not be used -> we will use the given app url from azure container instance
variable "bookstack-app-url" {
  type = string
  description = "Default app url for bookstack application"
  default = "http://localhost:8080"
}

variable "bookstack-app-key" {
  type = string
  description = "Bookstack App Key/Secret used for encryption"
  default = "thisIsAVerySecureNonProdSecret"
}
