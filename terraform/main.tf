terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
    docker = {
        source = "kreuzwerker/docker"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.azure-subscription-id
  tenant_id = var.azure-tenant_id
}

provider "docker" {

}

/*
The Bookstack Application should be installed in its own resource group

This Resource Group will be used for all resources later on
*/
resource "azurerm_resource_group" "rg-bookstack-prod-germanywestcentral-001" {
  name = "rg-bookstack-prod-germanywestcentral-001"
  location = "West Europe"
}

resource "azurerm_virtual_network" "vnet-bookstack-prod-germanywestcentral-001" {
  name = "vnet-bookstack-prod-germanywestcentral-001"
  address_space = [ "10.0.0.0/16" ]
  location = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.location
  resource_group_name = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
}

resource "azurerm_subnet" "snet-bookstack-prod-germanywestcentral-001" {
  name = "snet-bookstack-prod-germanywestcentral-001"
  resource_group_name = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
  virtual_network_name = azurerm_virtual_network.vnet-bookstack-prod-germanywestcentral-001.name
  address_prefixes = [ "10.0.1.0/24" ]
}


/*
Bookstack requires a local image repository

we will use azure container registry to store a local copy of bookstack inside

our azure container instance will pull the image and runs it
*/
resource "azurerm_container_registry" "crbookstackprodgermanywestcentral001" {
  name = "crbookstackprodgermanywestcentral001"
  location = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.location
  resource_group_name = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
  sku = "Basic"
}

/*
This step will build the docker image locally and push it to the newly created registry
*/
resource "null_resource" "build_bookstack_docker_image_locally" {
  triggers = {
    image_name = "bookstack-app"
    image_tag = "latest"
    registry_uri = azurerm_container_registry.crbookstackprodgermanywestcentral001.login_server
    dockerfile_path = "../Dockerfile"
    dockerfile_context = "../"
    registry_admin_username = azurerm_container_registry.crbookstackprodgermanywestcentral001.admin_username
    registry_admin_password = azurerm_container_registry.crbookstackprodgermanywestcentral001.admin_password
  }

  provisioner "local-exec" {
    command = "./scripts/build_bookstack_docker_image_locally.sh ${self.triggers.image_name} ${self.triggers.image_tag} ${self.triggers.registry_uri} ${self.triggers.dockerfile_path} ${self.triggers.dockerfile_context} ${self.triggers.registry_admin_username} ${self.triggers.registry_admin_password}"
    interpreter = [ "bash", "-c" ]
  }
}



/*
This Storage Account will hold the data directory of both mysql and bookstack

A separeted Storage Share will be used for both containers
*/
resource "azurerm_storage_account" "stbkstkgwc001" {
  name = "stbkstkgwc001"
  resource_group_name = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
  location = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.location
  account_tier = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_share" "mysqlshare" {
  name = "mysqlshare"
  storage_account_id = azurerm_storage_account.stbkstkgwc001.id
  quota = 50
}

resource "azurerm_storage_share" "bookstackshare" {
  name = "bookstackshare"
  storage_account_id = azurerm_storage_account.stbkstkgwc001.id
  quota = 50
}

/*
In order to run bookstack we will use azure container instances

bookstack will have a public ip with port 443 exposed to it
mysql will have a private ip inside the network and is only reached by the bookstack container
*/
resource "azurerm_container_group" "ci-bookstack-prod-germanywestcentral-001" {
  name = "ci-bookstack-prod-germanywestcentral-001"
  location = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.location
  resource_group_name = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
  os_type = "Linux"
  ip_address_type = "Public"
  dns_name_label = "bookstack-application"
  exposed_port = [{
    port = 443
    protocol = "TCP"
  }]

  container {
    name = "bookstack-mysql"
    image = "mysql:8.0"
    cpu = "1.0"
    memory = "2.0"

    environment_variables = {
      MYSQL_ROOT_PASSWORD = var.bookstack-db-root-pw
      MYSQL_DATABASE = var.bookstack-db-name
      MYSQL_USER = var.bookstack-db-user
      MYSQL_PASSWORD = var.bookstack-db-password
    }

    ports {
      port = 1433
      protocol = "TCP"
    }

    volume {
      name = "mysql-volume"
      mount_path = "/var/lib/mysql"
      share_name = azurerm_storage_share.mysqlshare.name
      storage_account_name = azurerm_storage_account.stbkstkgwc001.name
      storage_account_key = azurerm_storage_account.stbkstkgwc001.primary_access_key
    }
  }

  container {
    name = "bookstack-application"
    image = "linuxserver/bookstack" # public dockerhub image is a bad idea due to docker rate limiting
    cpu = "1.0"
    memory = "2.0"

    environment_variables = {
      DB_HOST = "bookstack-mysql"
      DB_DATABASE = var.bookstack-db-name
      DB_USERNAME = var.bookstack-db-user
      DB_PASSWORD = var.bookstack-db-password
    }

    ports {
      port = 443
      protocol = "TCP"
    }

    volume {
      name = "bookstack-volume"
      mount_path = "/config"
      share_name = azurerm_storage_share.bookstackshare.name
      storage_account_name = azurerm_storage_account.stbkstkgwc001.name
      storage_account_key = azurerm_storage_account.stbkstkgwc001.primary_access_key
    }
  }
}




