# Backstage + Microsoft Entra ID

Set up Microsoft sign-in and Entra ID user/group import for a local [Backstage](https://backstage.io/) instance using OpenTofu or Terraform.

This repository contains the companion code for an upcoming blog series. The series is not published yet.

This repository provisions the identity resources and generates the Backstage configuration. It does **not** contain a Backstage application or deploy Backstage, AKS, or other Azure hosting infrastructure.

## What it sets up

- A single-tenant Entra ID app registration named `backstage` and its service principal.
- A `backstage-users` security group, with the provisioning identity added as an owner and member.
- Microsoft Graph delegated permission grants for sign-in and application permission grants (admin consent) for catalog sync.
- An application client secret with a 180-day lifetime and an apply-driven rotation timer.
- A generated `../backstage/app-config.local.yaml` containing the Microsoft authentication and Microsoft Graph catalog provider settings.

The catalog configuration imports the `backstage-users` group and its direct user members rather than the entire directory.

## OpenTofu or Terraform?

The configuration uses no OpenTofu-specific features. It uses standard HCL and the `hashicorp/azuread`, `hashicorp/local`, and `hashicorp/time` providers. The checked-in `.terraform.lock.hcl` contains provider entries for both `registry.opentofu.org` and `registry.terraform.io`.

The examples below use `tofu`. For a fresh deployment, substitute `terraform` for `tofu` in the same commands. Use one tool consistently for a deployment: configuration compatibility does not guarantee that existing state can be moved freely between CLI versions. Back up state and check state-format and provider-address compatibility before switching tools.

## Prerequisites

- Git, [OpenTofu](https://opentofu.org/docs/intro/install/) or [Terraform](https://developer.hashicorp.com/terraform/install), and the [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli).
- An Entra ID tenant and a user authorized to manage app registrations, security groups, and delegated permission grants, and to grant Microsoft Graph application permissions. **Apply grants admin consent**, so app registration ownership alone is not enough. Microsoft documents **Privileged Role Administrator** as a supported role for granting Microsoft Graph application permissions; Application Administrator and Cloud Application Administrator cannot grant those permissions. See the [admin consent prerequisites](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/grant-admin-consent#prerequisites).
- A separate Backstage application with the [Microsoft authentication provider](https://backstage.io/docs/auth/microsoft/provider/) and [Microsoft Graph catalog module](https://backstage.io/docs/integrations/azure/org/) installed and registered. Follow those guides to enable Microsoft sign-in in the frontend as well. Generating YAML does not install or enable the plugins.

Use a development tenant where you are authorized to grant these permissions. No Azure subscription or Azure hosting resources are required for this configuration.

## Permissions granted

Applying this configuration grants the following Microsoft Graph permissions:

- **Delegated permissions for sign-in:** `openid`, `profile`, `email`, `User.Read`, and `offline_access`.
- **Application permissions for catalog sync:** `User.Read.All`, `GroupMember.Read.All`, and `Group.Read.All`.

The application permissions allow tenant-wide directory reads. The group filters narrow what Backstage imports, not what the application is authorized to read. Review these permissions before applying.

## Getting started

### 1. Prepare your workspace

This repository is intended to sit alongside the companion [Backstage application repository](https://github.com/pauldotyu/backstage). Follow that repository's setup instructions to prepare the application.

The `../backstage/app-config.local.yaml` output path is intentional and expects this sibling directory layout:

```text
workspace/
  backstage-azure/   # This repository
  backstage/         # pauldotyu/backstage
```

From your workspace directory, clone both repositories. Skip either clone command if you already have that repository in place:

```bash
git clone https://github.com/pauldotyu/backstage.git
git clone https://github.com/pauldotyu/backstage-azure.git
cd backstage-azure
```

You can also use your own Backstage application with the providers listed in the prerequisites. If it lives elsewhere, update `local_file.backstage_values.filename` in [`main.tf`](main.tf) before applying.

### 2. Authenticate and apply

Use interactive Azure CLI user authentication for this walkthrough. The configuration adds the current provisioning identity to `backstage-users`; authenticating as a service principal would not add your user account.

**Back up any existing `../backstage/app-config.local.yaml` before applying.** The generated file replaces the whole file rather than merging with it, and it contains a plaintext client secret. Ensure it is ignored by your Backstage application's Git repository.

Run these commands from this repository's root, replacing `<tenant-id>` with your Entra tenant ID:

```bash
az login --tenant "<tenant-id>" --allow-no-subscriptions

tofu init
tofu plan
tofu apply
```

Review the plan before approving the apply. No `.tfvars` file is required; names, URLs, and the output path are currently defined directly in `main.tf`.

### 3. Verify the resources and configuration

After a successful apply:

1. In the Microsoft Entra admin center, open **App registrations**, select the created `backstage` application, and check **API permissions**. The permissions listed above should show admin consent as granted. No separate manual consent step is required.
2. Open **Groups**, select the created `backstage-users` group, and confirm that your signed-in provisioning user is a direct member.
3. Confirm that `../backstage/app-config.local.yaml` exists and contains the `auth` and `catalog` sections. Treat its contents as sensitive: the client secret is written directly into the file.

### 4. Start Backstage and sign in

From this repository's root, switch to your Backstage application and start it using its normal local development command, typically:

```bash
cd ../backstage
yarn start
```

Ensure your startup command loads `app-config.local.yaml` alongside the application's base configuration. Restart Backstage if it was already running when you applied.

Open `http://localhost:3000`. Wait for the Microsoft Graph provider to import your user before signing in with Microsoft; check the backend logs for catalog import errors. The configured `emailMatchingUserEntityAnnotation` resolver requires a catalog user entity whose `microsoft.com/email` annotation matches the authenticated email address.

After signing in, check the catalog's **User** and **Group** kinds for your user and the `backstage-users` group.

To import additional users, add them as direct members of `backstage-users` and allow another catalog sync to run. This group scopes the catalog import; it is not an Entra application-assignment restriction.

## Troubleshooting

- **Apply fails with insufficient privileges or a 403:** Confirm that Azure CLI is signed in to the intended tenant and that your user has the permissions listed in the prerequisites. If your tenant uses Privileged Identity Management, activate the required role before authenticating and applying again. Do not assume that a failed apply rolled back resources already created.
- **Microsoft sign-in is missing:** Install and register the Microsoft authentication backend module and enable Microsoft on the frontend sign-in page. The generated YAML does not do this for you.
- **Sign-in succeeds with Microsoft but Backstage cannot resolve your identity:** Confirm that your user is a direct member of `backstage-users`, that catalog sync has completed, and that the imported user's `microsoft.com/email` annotation matches the sign-in email.
- **Users or groups do not appear:** Check that the Microsoft Graph catalog module is registered, the generated configuration is loaded, and the application permissions show admin consent as granted. Inspect the backend logs for Graph errors. Sync runs every 30 minutes, so membership changes are not immediate.

## Defaults and lifecycle

- **Local URLs:** The application homepage is `http://localhost:3000/`, and the OAuth callback is `http://localhost:7007/api/auth/microsoft/handler/frame`. Update `main.tf` and your Backstage settings together if those URLs change.
- **Backstage configuration:** [`backstage-app-config.tmpl`](backstage-app-config.tmpl) selects the `development` authentication environment and schedules catalog sync every 30 minutes with a 3-minute timeout. Changes to the template take effect in the generated file on the next apply.
- **Secret rotation:** The secret expires after 180 days. The rotation timer is evaluated during an apply, not by a background service. Once rotation is due, an apply rotates the secret and rewrites the configuration; reload Backstage to pick up the new credentials. Without that apply, the secret can expire and break authentication and catalog sync.
- **Sensitive files:** Local state (`terraform.tfstate` and its backups) and the generated YAML contain the client secret. Keep them out of version control and restrict access. This repository ignores state files, but its `.gitignore` does not protect files in the sibling Backstage repository.

## Cleanup

Return to this repository's root (for the default layout, run `cd ../backstage-azure` from your Backstage application). Use the same CLI and state used to create the resources:

```bash
tofu destroy
```

Destroying removes the managed Entra resources and the generated `app-config.local.yaml`. Back up any local configuration changes you need to keep first.
