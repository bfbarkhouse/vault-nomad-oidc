#Reference tutorial: https://developer.hashicorp.com/nomad/tutorials/single-sign-on/sso-oidc-vault

#Uncomment if the userpass auth backend doesn't exist yet
# resource "vault_auth_backend" "userpass" {
#   type = "userpass"
# }

#Comment out this data block if you need to create the userpass auth backend 
data "vault_auth_backend" "userpass" {
  path = "userpass"
}

#Create the userpass account. Not suitable for production.
resource "vault_generic_endpoint" "oidc-user" {
  #Uncomment if you are creating a userpass auth backend  
  #depends_on           = [vault_auth_backend.userpass]
  path                 = "auth/userpass/users/oidc-user"
  ignore_absent_fields = true

  data_json = <<EOT
{
  "policies": ["default"],
  "password": "password"
}
EOT
}

#A client may have multiple accounts with various identity providers that are enabled on the Vault server. 
#Vault clients can be mapped as entities and their corresponding accounts with authentication providers can be mapped as aliases.
#Create an entity
resource "vault_identity_entity" "oidc-user" {
  name = "oidc-user"
}

#Create a group and add the user entity as a member
resource "vault_identity_group" "test-group" {
  name              = "test-group"
  type              = "internal"
  member_entity_ids = [vault_identity_entity.oidc-user.id]
}

#Create an entity alias that maps the oidc-user entity with the oidc-user user
resource "vault_identity_entity_alias" "oidc-user-alias" {
  #name matches the username in the userpass backend
  name = "oidc-user"
  #Uncomment this if you are creating a userpass auth backend
  #mount_accessor  = vault_auth_backend.userpass.accessor
  #Comment this out if you are creating a userpass auth backend
  mount_accessor = data.vault_auth_backend.userpass.accessor
  canonical_id   = vault_identity_entity.oidc-user.id
}

#A Vault OIDC client connects a resource called an OIDC assignment, an encryption key, a client callback URL and a time-to-live on verification together.
#An OIDC assignment describes the list of the Vault entities and groups allowed to authenticate with this client.
#Create an assignment that authorizes the oidc-user entity and test-group group.
resource "vault_identity_oidc_assignment" "default" {
  name = "assignment"
  entity_ids = [
    vault_identity_entity.oidc-user.id,
  ]
  group_ids = [
    vault_identity_group.test-group.id,
  ]
}

resource "vault_identity_oidc_key" "key" {
  name               = "key"
  algorithm          = "RS256"
  allowed_client_ids = ["*"]
  verification_ttl   = 7200
  rotation_period    = 3600
}

#Create the Nomad OIDC client
resource "vault_identity_oidc_client" "nomad" {
  name = "nomad"
  #Redirect URIs use the Nomad cluster address
  redirect_uris = [
    "http://10.0.0.202:4649/oidc/callback",
    "http://10.0.0.202:4646/ui/settings/tokens"
  ]
  assignments = [
    vault_identity_oidc_assignment.default.name
  ]
  id_token_ttl     = 1800
  access_token_ttl = 3600
}

#A Vault OIDC provider supports one or more clients and Vault OIDC scopes. 
#These scopes define metadata claims expressed in a template. 
#Claims are key-value pairs that contain information about a user and the OIDC service.

#Create the user scope 
resource "vault_identity_oidc_scope" "user" {
  name        = "user"
  template    = "{\"username\":{{identity.entity.name}}}"
  description = "The user scope provides claims using Vault identity entity metadata"
}

#Create the group scope 
resource "vault_identity_oidc_scope" "groups" {
  name        = "groups"
  template    = "{\"groups\":{{identity.entity.groups.names}}}"
  description = "The groups scope provides the groups claim using Vault group membership"
}

#Create a Vault OIDC provider and provide it a list of client IDs and scopes. The provider grants access to the nomad client.
resource "vault_identity_oidc_provider" "provider" {
  name = "default"
  #Set to true if your Vault issuer endpoint uses TLS
  https_enabled = false
  allowed_client_ids = [
    vault_identity_oidc_client.nomad.client_id
  ]
  scopes_supported = [
    vault_identity_oidc_scope.groups.name
  ]
}

#Create a Nomad policy that allows read access to the "default" namespace
resource "nomad_acl_policy" "oidc-read" {
  name      = "oidc-read"
  rules_hcl = <<EOT
namespace "default" {
  policy = "read"
}

node {
  policy = "read"
}
EOT
}

#Create a corresponding role that contains the policy
resource "nomad_acl_role" "oidc-read" {
  name = "oidc-read"

  policy {
    name = nomad_acl_policy.oidc-read.name
  }
}

#Create a new OIDC authentication method and configure it to use the Vault OIDC provider.
resource "nomad_acl_auth_method" "vault" {
  name           = "vault"
  type           = "OIDC"
  token_locality = "global"
  max_token_ttl  = "1h"
  default        = false

  config {
    oidc_discovery_url = vault_identity_oidc_provider.provider.issuer
    oidc_client_id     = vault_identity_oidc_client.nomad.client_id
    oidc_client_secret = vault_identity_oidc_client.nomad.client_secret
    bound_audiences    = [vault_identity_oidc_client.nomad.client_id]
    oidc_scopes        = ["groups"]
    #Redirect URIs use the Nomad cluster address
    allowed_redirect_uris = [
      "http://10.0.0.202:4649/oidc/callback",
      "http://10.0.0.202:4646/ui/settings/tokens",
    ]
    list_claim_mappings = {
      "groups" : "roles"
    }
  }
}

#Create a binding rule to evaluate OIDC claims into Nomad policies and roles.
resource "nomad_acl_binding_rule" "oidc-read" {
  auth_method = nomad_acl_auth_method.vault.name
  selector    = "\"test-group\" in list.roles"
  bind_type   = "role"
  bind_name   = nomad_acl_role.oidc-read.name
}

#You can now log in via Vault OIDC in the UI or CLI:
#nomad login -method=vault -oidc-callback-addr=10.0.0.202:4649