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
  tenant_id       = var.azure-tenant_id
}

provider "docker" {

}

/*
The Bookstack Application should be installed in its own resource group

This Resource Group will be used for all resources later on
*/
resource "azurerm_resource_group" "rg-bookstack-prod-germanywestcentral-001" {
  name     = "rg-bookstack-prod-germanywestcentral-001"
  location = "West Europe"
}

resource "azurerm_virtual_network" "vnet-bookstack-prod-germanywestcentral-001" {
  name                = "vnet-bookstack-prod-germanywestcentral-001"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.location
  resource_group_name = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
}

// smallest host subnet for azure container instance
resource "azurerm_subnet" "snet-bookstack-prod-germanywestcentral-001" {
  name                 = "snet-bookstack-prod-germanywestcentral-001"
  resource_group_name  = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
  virtual_network_name = azurerm_virtual_network.vnet-bookstack-prod-germanywestcentral-001.name
  address_prefixes     = ["10.0.1.0/28"]

  // delegate this subnet for container instance use only
  delegation {
    name = "snet-bookstack-prod-germanywestcentral-001-ci-delegation"
    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

// single host application gateway for azure applicaton proxy
resource "azurerm_subnet" "snet-bookstack-prod-germanywestcentral-002" {
  name = "snet-bookstack-prod-germanywestcentral-002"
  resource_group_name = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
  virtual_network_name = azurerm_virtual_network.vnet-bookstack-prod-germanywestcentral-001.name
  address_prefixes = ["10.0.1.16/28"]
}

/*
Bookstack will be accessible through an ingress controller with a public ip address
This public ip address will be able to 
*/
resource "azurerm_public_ip" "pip-bookstack-prod-germanywestcentral-001" {
  name                = "pip-bookstack-prod-germanywestcentral-001"
  location            = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.location
  resource_group_name = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
  allocation_method   = "Static"
  sku                 = "Standard"
  ip_version =        "IPv4"
  idle_timeout_in_minutes = 4 // what is this?
  zones = [ "1" ]
}

resource "azurerm_application_gateway" "agw-bookstack-prod-germanywestcentral-001" {
  depends_on = [ azurerm_container_group.ci-bookstack-prod-germanywestcentral-001 ]

  name = "agw-bookstack-prod-germanywestcentral-001"
  location = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.location
  resource_group_name = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
  
  sku {
    name = "Basic" // keep it minimal
    tier = "Basic"
    capacity = 1 // only one instance no ha required
  }

  gateway_ip_configuration {
    name = "agw-bookstack-prod-germanywestcentral-001-gw-ip"
    subnet_id = azurerm_subnet.snet-bookstack-prod-germanywestcentral-002.id
  }

  // important for http listener below
  frontend_ip_configuration {
    name = "agw-bookstack-prod-germanywestcentral-001-fe-ip"
    public_ip_address_id = azurerm_public_ip.pip-bookstack-prod-germanywestcentral-001.id
  }

  // important for http listener below
  frontend_port {
    name = "agw-bookstack-prod-germanywestcentral-001-fe-pt"
    port = 80 // change this later to https
  }
  /*
    frontend_port {
    name = "frontend-port-https"
    port = 443
  }
  */

  // important for request routing rule below
  backend_address_pool {
    name = "agw-bookstack-prod-germanywestcentral-001-be-addr-pool"
    ip_addresses = [ azurerm_container_group.ci-bookstack-prod-germanywestcentral-001.ip_address ]
  }

  // important for request routing rule below
  backend_http_settings {
    name = "agw-bookstack-prod-germanywestcentral-001-be-set"
    cookie_based_affinity = "Disabled" // no cookies required -> no load balancing
    port = 8080 // bookstack runs on 8080
    protocol = "Http"
    request_timeout = 20 // default request timeout
  }

  http_listener {
    name = "agw-bookstack-prod-germanywestcentral-001-http-listener"
    frontend_ip_configuration_name = "agw-bookstack-prod-germanywestcentral-001-fe-ip"
    frontend_port_name = "agw-bookstack-prod-germanywestcentral-001-fe-pt"
    protocol = "Http" // change this later to https
  }

  request_routing_rule {
    name = "agw-bookstack-prod-germanywestcentral-001-rule1"
    priority = "1" // import for newer api versions
    rule_type = "Basic"
    http_listener_name = "agw-bookstack-prod-germanywestcentral-001-http-listener"
    backend_address_pool_name = "agw-bookstack-prod-germanywestcentral-001-be-addr-pool"
    backend_http_settings_name = "agw-bookstack-prod-germanywestcentral-001-be-set"
  }

  // disable http2 by default
  enable_http2 = false
}

/*
Bookstack requires a local image repository

we will use azure container registry to store a local copy of bookstack inside

our azure container instance will pull the image and runs it
*/
resource "azurerm_container_registry" "crbookstackprodgermanywestcentral001" {
  name                = "crbookstackprodgermanywestcentral001"
  location            = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.location
  resource_group_name = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
  sku                 = "Basic"
  admin_enabled       = true // enable admin access for local docker image push
}

/*
This step will build the docker image locally and push it to the newly created registry
*/
resource "null_resource" "build_bookstack_docker_image_locally" {
  depends_on = [azurerm_container_registry.crbookstackprodgermanywestcentral001] // azure container repository should be ready before image build

  triggers = {
    image_name              = "solidnerd/bookstack"
    image_tag               = "24.12.1"
    registry_uri            = azurerm_container_registry.crbookstackprodgermanywestcentral001.login_server
    dockerfile_path         = "../Dockerfile"
    dockerfile_context      = "../"
    registry_admin_username = azurerm_container_registry.crbookstackprodgermanywestcentral001.admin_username
    registry_admin_password = azurerm_container_registry.crbookstackprodgermanywestcentral001.admin_password
  }

  provisioner "local-exec" {
    command     = "./scripts/build_push_docker_image.sh ${self.triggers.image_name} ${self.triggers.image_tag} ${self.triggers.registry_uri} ${self.triggers.dockerfile_path} ${self.triggers.dockerfile_context} ${self.triggers.registry_admin_username} ${self.triggers.registry_admin_password}"
    interpreter = ["bash", "-c"]
  }
}

/*
Copy Mysql Image from Docker Hub to prior created azure container registry with local-exec
*/
resource "null_resource" "import_mysql_image_to_registry" {
  depends_on = [azurerm_container_registry.crbookstackprodgermanywestcentral001] // also depends on registry

  triggers = {
    image_name              = "mysql"
    image_tag               = "9.2.0"
    registry_uri            = azurerm_container_registry.crbookstackprodgermanywestcentral001.login_server
    registry_admin_username = azurerm_container_registry.crbookstackprodgermanywestcentral001.admin_username
    registry_admin_password = azurerm_container_registry.crbookstackprodgermanywestcentral001.admin_password
  }

  provisioner "local-exec" {
    command     = "./scripts/pull_mysql_and_push_image.sh ${self.triggers.image_name} ${self.triggers.image_tag} ${self.triggers.registry_uri} ${self.triggers.registry_admin_username} ${self.triggers.registry_admin_password}"
    interpreter = ["bash", "-c"]
  }
}


/*
disabled due to missing platform specifier for az acr import cmdlet
resource "null_resource" "import_mysql_image_to_registry" {
  provisioner "local-exec" {
        command = <<EOT
      az acr import --name ${azurerm_container_registry.crbookstackprodgermanywestcentral001.name} \
      --source docker.io/library/mysql:9.2.0 \
      --image mysql:9.2.0 \
      --query "image.name"
    EOT
  }
  depends_on = [ azurerm_container_registry.crbookstackprodgermanywestcentral001 ]
}
*/



/*
This Storage Account will hold the data directory of both mysql and bookstack

A separeted Storage Share will be used for both containers
*/
resource "azurerm_storage_account" "stbkstkgwc001" {
  name                     = "stbkstkgwc001"
  resource_group_name      = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name
  location                 = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_share" "mysqlshare" {
  name               = "mysqlshare"
  storage_account_id = azurerm_storage_account.stbkstkgwc001.id
  quota              = 50
}

resource "azurerm_storage_share" "bookstackshareuploads" {
  name               = "bookstackshareuploads"
  storage_account_id = azurerm_storage_account.stbkstkgwc001.id
  quota              = 50
}

resource "azurerm_storage_share" "bookstacksharestorageuploads" {
  name               = "bookstacksharestorageuploads"

  storage_account_id = azurerm_storage_account.stbkstkgwc001.id
  quota              = 50
  
}

/*
In order to run bookstack we will use azure container instances

bookstack will have a public ip with port 443 exposed to it
mysql will have a private ip inside the network and is only reached by the bookstack container
*/
resource "azurerm_container_group" "ci-bookstack-prod-germanywestcentral-001" {
  depends_on = [azurerm_container_registry.crbookstackprodgermanywestcentral001, // depends on all docker images and registry
    azurerm_storage_account.stbkstkgwc001,
    null_resource.build_bookstack_docker_image_locally,
  null_resource.import_mysql_image_to_registry]

  name                = "ci-bookstack-prod-germanywestcentral-001"
  location            = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.location
  resource_group_name = azurerm_resource_group.rg-bookstack-prod-germanywestcentral-001.name

  os_type         = "Linux"
  ip_address_type = "Private"                                                      // get ip from internal subnet - will be used for azure application gateway later on
  subnet_ids      = [azurerm_subnet.snet-bookstack-prod-germanywestcentral-001.id] // ip address type Private needs a subnet_id

  exposed_port = [{
    port     = 8080
    protocol = "TCP" // allow bookstack access
    }, {
    port     = 3306
    protocol = "TCP" // allow mysql access
    }]

  image_registry_credential {
    username = azurerm_container_registry.crbookstackprodgermanywestcentral001.admin_username
    password = azurerm_container_registry.crbookstackprodgermanywestcentral001.admin_password
    server   = azurerm_container_registry.crbookstackprodgermanywestcentral001.login_server
  }

  container {
    name   = "mysql"
    image  = "${azurerm_container_registry.crbookstackprodgermanywestcentral001.login_server}/mysql:9.2.0"
    cpu    = "1.0"
    memory = "2.0"

    environment_variables = {
      MYSQL_ROOT_PASSWORD = var.bookstack-db-root-pw
      MYSQL_DATABASE      = var.bookstack-db-name
      MYSQL_USER          = var.bookstack-db-user
      MYSQL_PASSWORD      = var.bookstack-db-password
    }

    ports {
      port     = 3306
      protocol = "TCP"
    }

/*
    volume {
      name                 = "mysql-volume"
      mount_path           = "/var/lib/mysql"
      read_only = false
      share_name           = azurerm_storage_share.mysqlshare.name
      storage_account_name = azurerm_storage_account.stbkstkgwc001.name
      storage_account_key  = azurerm_storage_account.stbkstkgwc001.primary_access_key
    }
    */
  }

  container {

    name  = "bookstack"
    image = "${azurerm_container_registry.crbookstackprodgermanywestcentral001.login_server}/solidnerd/bookstack:24.12.1"

    cpu    = "1.0"
    memory = "2.0"

    environment_variables = {
      // why using localhost??? -> Azure container instance runs on kubernetes -> all containers are running inside a single pod!
      DB_HOST     = "127.0.0.1:3306" // IMPORTANT!!! for laravel 5.x -> change it directly to loopback ip
      DB_DATABASE = var.bookstack-db-name
      DB_USERNAME = var.bookstack-db-user
      DB_PASSWORD = var.bookstack-db-password
      APP_URL     = var.bookstack-app-url
      APP_KEY     = var.bookstack-app-key
    }

    ports {
      port     = 8080
      protocol = "TCP"
    }

    /*
    volume {
      name                 = "bookstack-volume-uploads"
      mount_path           = "/var/www/bookstack/public/uploads"
      share_name           = azurerm_storage_share.bookstackshareuploads.name
      storage_account_name = azurerm_storage_account.stbkstkgwc001.name
      storage_account_key  = azurerm_storage_account.stbkstkgwc001.primary_access_key
    }
*/
    /*
    volume {
      name                 = "bookstack-volume-storage-uploads"
      mount_path           = "/var/www/bookstack/storage/uploads"
      share_name           = azurerm_storage_share.bookstacksharestorageuploads.name
      storage_account_name = azurerm_storage_account.stbkstkgwc001.name
      storage_account_key  = azurerm_storage_account.stbkstkgwc001.primary_access_key
    }
    */
  }
}