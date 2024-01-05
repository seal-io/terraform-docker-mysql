locals {
  project_name     = coalesce(try(var.context["project"]["name"], null), "default")
  project_id       = coalesce(try(var.context["project"]["id"], null), "default_id")
  environment_name = coalesce(try(var.context["environment"]["name"], null), "test")
  environment_id   = coalesce(try(var.context["environment"]["id"], null), "test_id")
  resource_name    = coalesce(try(var.context["resource"]["name"], null), "example")
  resource_id      = coalesce(try(var.context["resource"]["id"], null), "example_id")

  namespace     = join("-", [local.project_name, local.environment_name])
  domain_suffix = coalesce(var.infrastructure.domain_suffix, "cluster.local")

  labels = {
    "walrus.seal.io/catalog-name"     = "terraform-docker-mysql"
    "walrus.seal.io/project-id"       = local.project_id
    "walrus.seal.io/environment-id"   = local.environment_id
    "walrus.seal.io/resource-id"      = local.resource_id
    "walrus.seal.io/project-name"     = local.project_name
    "walrus.seal.io/environment-name" = local.environment_name
    "walrus.seal.io/resource-name"    = local.resource_name
  }

  master_name = format("%s-master", local.resource_name)

  architecture = coalesce(var.architecture, "standalone")
}

#
# Ensure
#

data "docker_network" "network" {
  name = var.infrastructure.network_id

  lifecycle {
    postcondition {
      condition     = self.driver == "bridge"
      error_message = "Docker network driver must be bridge"
    }
  }
}

locals {
  volume_refer_database_data = {
    schema = "docker:localvolumeclaim"
    params = {
      name = "mysql"
    }
  }

  database = coalesce(var.database, "mydb")
  username = coalesce(var.username, "rdsuser")
  password = coalesce(var.password, substr(md5(local.username), 0, 16))
}

module "master" {
  source = "github.com/walrus-catalog/terraform-docker-containerservice?ref=v0.1.0&depth=1"

  context = {
    project = {
      name = local.project_name
      id   = local.project_id
    }
    environment = {
      name = local.environment_name
      id   = local.environment_id
    }
    resource = {
      name = local.master_name
      id   = local.resource_id
    }
  }

  infrastructure = {
    domain_suffix = local.domain_suffix
    network_id    = data.docker_network.network.id
  }

  containers = [
    #
    # Init Container
    #
    var.seeding.type == "url" ? {
      profile = "init"
      image   = "alpine"
      execute = {
        working_dir = "/"
        command = [
          "sh",
          "-c",
          "test -f /docker-entrypoint-initdb.d/init.sql || wget -c -S -O /docker-entrypoint-initdb.d/init.sql ${var.seeding.url.location}"
        ]
      }
      mounts = [
        {
          path   = "/docker-entrypoint-initdb.d"
          volume = "init"
        },
      ]
    } : null,

    #
    # Run Container
    #
    {
      image     = join(":", ["bitnami/mysql", var.engine_version])
      resources = var.resources
      envs = [
        {
          name  = "MYSQL_DATABASE"
          value = local.database
        },
        {
          name  = "MYSQL_USER"
          value = local.username
        },
        {
          name  = "MYSQL_PASSWORD"
          value = local.password
        },
        {
          name  = "MYSQL_ROOT_PASSWORD"
          value = local.password
        },
        {
          name  = "MYSQL_REPLICATION_MODE"
          value = "master"
        },
        {
          name  = "MYSQL_REPLICATION_USER"
          value = "my_repl_user"
        },
        {
          name  = "MYSQL_REPLICATION_PASSWORD"
          value = local.password
        },
      ]
      mounts = [
        {
          path         = "/bitnami/mysql/data"
          volume_refer = local.volume_refer_database_data # persistent
        },
        var.seeding.type == "url" ? {
          path   = "/docker-entrypoint-initdb.d"
          volume = "init"
        } : null,
      ]
      files = var.seeding.type == "text" ? [
        {
          path    = "/docker-entrypoint-initdb.d/init.sql"
          content = try(var.seeding.text.content, null)
        }
      ] : null
      ports = [
        {
          internal = 3306
          protocol = "tcp"
        }
      ]
      checks = [
        {
          type     = "execute"
          delay    = 10
          timeout  = 5
          interval = 15
          execute = {
            command = [
              "/opt/bitnami/scripts/mysql/healthcheck.sh"
            ]
          }
        }
      ]
    }
  ]
}

module "slave" {
  count = local.architecture == "replication" ? var.replication_readonly_replicas : 0

  source = "github.com/walrus-catalog/terraform-docker-containerservice?ref=v0.1.0&depth=1"

  context = {
    project = {
      name = local.project_name
      id   = local.project_id
    }
    environment = {
      name = local.environment_name
      id   = local.environment_id
    }
    resource = {
      name = format("%s-slave-%d", local.resource_name, count.index)
      id   = local.resource_id
    }
  }

  infrastructure = {
    network_id = data.docker_network.network.id
  }

  containers = [
    #
    # Run Container
    #
    {
      image     = join(":", ["bitnami/mysql", var.engine_version])
      resources = var.resources
      envs = [
        {
          name  = "MYSQL_MASTER_ROOT_PASSWORD"
          value = local.password
        },
        {
          name  = "MYSQL_REPLICATION_MODE"
          value = "slave"
        },
        {
          name  = "MYSQL_REPLICATION_USER"
          value = "my_repl_user"
        },
        {
          name  = "MYSQL_REPLICATION_PASSWORD"
          value = local.password
        },
        {
          name  = "MYSQL_MASTER_HOST"
          value = format("%s.%s.svc.%s", local.master_name, local.namespace, local.domain_suffix)

        },
      ]
      ports = [
        {
          internal = 3306
          protocol = "tcp"
        }
      ]
      checks = [
        {
          type     = "execute"
          delay    = 10
          timeout  = 5
          interval = 15
          execute = {
            command = [
              "/opt/bitnami/scripts/mysql/healthcheck.sh"
            ]
          }
        }
      ]
    }
  ]
}
