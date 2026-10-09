terraform {
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10.0"
    }
  }
}

data "azuread_client_config" "current" {}

data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000"
}

locals {
  msgraph_oauth2_permission_scope_ids = {
    for scope in data.azuread_service_principal.msgraph.oauth2_permission_scopes :
    scope.value => scope.id
  }

  # Application permissions used by the catalog msgraph provider to import users and groups
  msgraph_app_roles = ["User.Read.All", "GroupMember.Read.All", "Group.Read.All"]
}

# Members of this group are imported into the Backstage catalog and can sign in
resource "azuread_group" "backstage_users" {
  display_name     = "backstage-users"
  security_enabled = true
  owners           = [data.azuread_client_config.current.object_id]
}

resource "azuread_group_member" "me" {
  group_object_id  = azuread_group.backstage_users.object_id
  member_object_id = data.azuread_client_config.current.object_id
}

resource "time_rotating" "example" {
  rotation_days = 180
}

resource "azuread_application" "example" {
  display_name     = "backstage"
  owners           = [data.azuread_client_config.current.object_id]
  sign_in_audience = "AzureADMyOrg"

  web {
    homepage_url = "http://localhost:3000/"
    redirect_uris = [
      "http://localhost:7007/api/auth/microsoft/handler/frame"
    ]
  }

  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id

    resource_access {
      id   = local.msgraph_oauth2_permission_scope_ids["openid"]
      type = "Scope"
    }

    resource_access {
      id   = local.msgraph_oauth2_permission_scope_ids["profile"]
      type = "Scope"
    }

    resource_access {
      id   = local.msgraph_oauth2_permission_scope_ids["email"]
      type = "Scope"
    }

    resource_access {
      id   = local.msgraph_oauth2_permission_scope_ids["User.Read"]
      type = "Scope"
    }

    resource_access {
      id   = local.msgraph_oauth2_permission_scope_ids["offline_access"]
      type = "Scope"
    }

    dynamic "resource_access" {
      for_each = local.msgraph_app_roles
      content {
        id   = data.azuread_service_principal.msgraph.app_role_ids[resource_access.value]
        type = "Role"
      }
    }
  }

  password {
    display_name = "backstage"
    start_date   = time_rotating.example.id
    end_date     = timeadd(time_rotating.example.id, "4320h")
  }
}

resource "azuread_service_principal" "example" {
  client_id = azuread_application.example.client_id
}

resource "azuread_service_principal_delegated_permission_grant" "example" {
  service_principal_object_id          = azuread_service_principal.example.object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph.object_id
  claim_values                         = ["openid", "profile", "email", "User.Read", "offline_access"]
}

# Grant admin consent for app roles (application permissions)
resource "azuread_app_role_assignment" "example" {
  for_each            = toset(local.msgraph_app_roles)
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids[each.key]
  principal_object_id = azuread_service_principal.example.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

resource "local_file" "backstage_values" {
  filename = "../backstage/app-config.local.yaml"
  content = templatefile("backstage-app-config.tmpl",
    {
      AZURE_CLIENT_ID     = azuread_application.example.client_id
      AZURE_CLIENT_SECRET = tolist(azuread_application.example.password).0.value
      AZURE_TENANT_ID     = data.azuread_client_config.current.tenant_id
      AZURE_GROUP_ID      = azuread_group.backstage_users.object_id
    }
  )
}