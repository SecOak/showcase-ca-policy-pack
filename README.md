# Conditional Access policy pack

> **Showcase copy.** This is a sanitized example of my work, published for portfolio purposes.
> It is a snapshot, not an actively maintained project, and it has never been pointed at a real
> tenant from this repository. Issues and pull requests are welcome but may not get a reply.
> Contact: zachanger@outlook.com · [zachanger.com](https://zachanger.com)


## What is in the box

Eight Microsoft Entra Conditional Access policy templates, each shipped report-only
(`enabledForReportingButNotEnforced`) and excluding a your own break-glass group, so a
operator can review the impact before switching anything on.

| ID | Policy | Licence |
|---|---|---|
| CA001 | Require MFA for all users | Entra ID P1 |
| CA002 | Block legacy authentication | Entra ID P1 |
| CA003 | Require MFA for admins | Entra ID P1 |
| CA004 | Require compliant or hybrid joined device for admins | Entra ID P1 plus Intune |
| CA005 | Block unknown platforms | Entra ID P1 |
| CA006 | Sign-in frequency on unmanaged devices | Entra ID P1 |
| CA007 | Block high-risk sign-ins | Entra ID P2 |
| CA008 | Phishing-resistant MFA for admins | Entra ID P1 |

Templates live under `templates\`, one file per policy, listed with their licence and
deployment order in `manifest.json`. `schema\conditionalAccessTemplate.schema.json` validates
every template against the Microsoft Graph v1.0 `conditionalAccessPolicy` shape used here.

## What it does not do

This pack does not enforce anything by itself. Every template ships in report-only mode, and
nothing in the pack turns a policy on for you. A person decides that, in the Entra admin center,
once they are satisfied with what the report-only period showed.

This pack does not monitor your tenant. There is no scheduled task, no background service, and
no connection back to the pack after a script finishes running. `Compare-CaBaseline.ps1` only
checks the tenant when you run it yourself.

This pack does not come with support. It is provided as-is. There is no help desk, no service level
agreement, and no guarantee that it suits a particular tenant's needs. See "No warranty" below.

## Prerequisites

Before running anything in this pack, the tenant needs:

- PowerShell 7 on the machine running the scripts.
- The `Microsoft.Graph.Authentication` module installed for the account that will run the
  scripts.
- An account with the Conditional Access Administrator role (or a role that includes its
  permissions) to run `Import-CaPolicyPack.ps1` with `-Apply`.
- Two cloud-only break-glass accounts, each excluded from Conditional Access, placed in a
  dedicated security group. The group's object ID is passed to `Import-CaPolicyPack.ps1` as
  `-BreakGlassGroupId` and is excluded from every policy this pack creates.
- Microsoft Entra ID P1. CA007 (block high-risk sign-ins) additionally requires Entra ID P2,
  because it depends on Entra ID Protection risk scoring; pass `-IncludeP2` to import it.
- Admin consent for the three delegated scopes below, on the first sign-in. A Global
  Administrator or a Privileged Role Administrator must grant that consent; a Conditional
  Access Administrator alone cannot.

## Security Defaults

Microsoft Entra does not allow Conditional Access policies while Security Defaults is turned
on, so Security Defaults must be turned off before the import runs. Turning it off removes the
multifactor authentication prompts that Security Defaults enforced for everyone, so there is a
short gap in that protection until a replacement policy is enabled.

If Security Defaults is on today, plan the switch as one short window: turn it off, run the
import, review the report-only results for one or two days instead of the full review period,
then enable CA002 and CA003 first to block legacy authentication and bring back multifactor
authentication for administrators. Other users have no multifactor prompt until CA001 is
enabled, so move CA001 up next. Leave the remaining policies in report-only for the normal
review period described in `DEPLOYMENT-ORDER.md`.

Microsoft may also create Microsoft-managed policies in your tenant, in report-only or enabled
state. They do not block this pack; review them separately in the Entra admin center.

## Permissions requested

`Import-CaPolicyPack.ps1` asks for three delegated Microsoft Graph scopes when you sign in:

- `Policy.Read.All`, to read existing Conditional Access policies and named locations so the
  script can check for duplicates and resolve placeholders before writing anything.
- `Policy.ReadWrite.ConditionalAccess`, to create the report-only policies in the tenant.
- `GroupMember.Read.All`, to confirm the break-glass group exists, is security-enabled, and has
  at least one member before any policy that excludes it is created.

`Export-CaBaseline.ps1` and `Compare-CaBaseline.ps1` ask only for `Policy.Read.All`, since they
never write to the tenant.

These scripts store no credentials anywhere, on disk or otherwise. They have no app-only sign-in
mode; every run is an interactive, delegated sign-in tied to the person running the script and
the role assigned to their account.

## Quick start

Run these from PowerShell 7, in order:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
.\Import-CaPolicyPack.ps1 -TenantId '<tenant-id-or-verified-domain>' -BreakGlassGroupId '<break-glass-group-object-id>' -WhatIf
.\Import-CaPolicyPack.ps1 -TenantId '<tenant-id-or-verified-domain>' -BreakGlassGroupId '<break-glass-group-object-id>' -Apply
.\Export-CaBaseline.ps1
.\Compare-CaBaseline.ps1
```

The first `-WhatIf` run makes no changes; it shows what would be created. The `-Apply` run
creates the report-only policies in the tenant; on its own it imports six templates, since CA007
and CA008 need an extra switch each. Add `-IncludeP2` for CA007 and `-IncludePhishingResistant`
for CA008 to import all eight. `Export-CaBaseline.ps1` writes the current tenant policies to
local files so you have a record before and after. `Compare-CaBaseline.ps1` checks the templates
against the live tenant (or an export folder) and reports whether each one is missing, matches,
differs, is still report-only, or has been enabled.

## What happens when you run Import

`Import-CaPolicyPack.ps1` runs five checks before it writes anything. If any check fails, the
script stops and makes zero writes:

1. Every template to be imported parses as valid JSON and passes the policy schema.
2. Every template's state is report-only. No parameter on this script can change a template to
   an enforced state.
3. No placeholder (such as `{{BREAK_GLASS_GROUP_ID}}`) is left unresolved after substitution.
4. The break-glass group exists, is security-enabled, and has at least one member.
5. Any named location a template references actually exists in the tenant.

If a template to be imported has the same display name (matched case-insensitively) as a policy
already in the tenant, the import skips that template and prints a warning rather than creating
a duplicate.

## Turning policies on

The templates in this pack arrive report-only on purpose. Moving a policy from report-only to
enforced, in what order, and how long to wait at each step, is covered in
[`DEPLOYMENT-ORDER.md`](DEPLOYMENT-ORDER.md).

## Licence

Released under the [MIT License](LICENSE).

## No warranty

This pack is provided as-is, without any warranty of any kind, express
or implied. The templates and scripts in this pack are a starting point for configuring
Conditional Access; they do not make a tenant secure, and they do not make a tenant compliant
with any regulation, framework, or contract. The operator is responsible for reviewing every policy
in report-only mode, for understanding what each policy does before enabling it, and for the
consequences of enabling it in their own tenant. The seller provides no support and accepts no
liability for any outcome of using this pack.

## What is in the box

Eight Microsoft Entra Conditional Access policy templates, each shipped report-only
(`enabledForReportingButNotEnforced`) and excluding a your own break-glass group, so a
operator can review the impact before switching anything on.

| ID | Policy | Licence |
|---|---|---|
| CA001 | Require MFA for all users | Entra ID P1 |
| CA002 | Block legacy authentication | Entra ID P1 |
| CA003 | Require MFA for admins | Entra ID P1 |
| CA004 | Require compliant or hybrid joined device for admins | Entra ID P1 plus Intune |
| CA005 | Block unknown platforms | Entra ID P1 |
| CA006 | Sign-in frequency on unmanaged devices | Entra ID P1 |
| CA007 | Block high-risk sign-ins | Entra ID P2 |
| CA008 | Phishing-resistant MFA for admins | Entra ID P1 |

Templates live under `templates\`, one file per policy, listed with their licence and
deployment order in `manifest.json`. `schema\conditionalAccessTemplate.schema.json` validates
every template against the Microsoft Graph v1.0 `conditionalAccessPolicy` shape used here.

## What it does not do

This pack does not enforce anything by itself. Every template ships in report-only mode, and
nothing in the pack turns a policy on for you. A person decides that, in the Entra admin center,
once they are satisfied with what the report-only period showed.

This pack does not monitor your tenant. There is no scheduled task, no background service, and
no connection back to the pack after a script finishes running. `Compare-CaBaseline.ps1` only
checks the tenant when you run it yourself.

This pack does not come with support. It is provided as-is. There is no help desk, no service level
agreement, and no guarantee that it suits a particular tenant's needs. See "No warranty" below.

## Prerequisites

Before running anything in this pack, the tenant needs:

- PowerShell 7 on the machine running the scripts.
- The `Microsoft.Graph.Authentication` module installed for the account that will run the
  scripts.
- An account with the Conditional Access Administrator role (or a role that includes its
  permissions) to run `Import-CaPolicyPack.ps1` with `-Apply`.
- Two cloud-only break-glass accounts, each excluded from Conditional Access, placed in a
  dedicated security group. The group's object ID is passed to `Import-CaPolicyPack.ps1` as
  `-BreakGlassGroupId` and is excluded from every policy this pack creates.
- Microsoft Entra ID P1. CA007 (block high-risk sign-ins) additionally requires Entra ID P2,
  because it depends on Entra ID Protection risk scoring; pass `-IncludeP2` to import it.
- Admin consent for the three delegated scopes below, on the first sign-in. A Global
  Administrator or a Privileged Role Administrator must grant that consent; a Conditional
  Access Administrator alone cannot.

## Security Defaults

Microsoft Entra does not allow Conditional Access policies while Security Defaults is turned
on, so Security Defaults must be turned off before the import runs. Turning it off removes the
multifactor authentication prompts that Security Defaults enforced for everyone, so there is a
short gap in that protection until a replacement policy is enabled.

If Security Defaults is on today, plan the switch as one short window: turn it off, run the
import, review the report-only results for one or two days instead of the full review period,
then enable CA002 and CA003 first to block legacy authentication and bring back multifactor
authentication for administrators. Other users have no multifactor prompt until CA001 is
enabled, so move CA001 up next. Leave the remaining policies in report-only for the normal
review period described in `DEPLOYMENT-ORDER.md`.

Microsoft may also create Microsoft-managed policies in your tenant, in report-only or enabled
state. They do not block this pack; review them separately in the Entra admin center.

## Permissions requested

`Import-CaPolicyPack.ps1` asks for three delegated Microsoft Graph scopes when you sign in:

- `Policy.Read.All`, to read existing Conditional Access policies and named locations so the
  script can check for duplicates and resolve placeholders before writing anything.
- `Policy.ReadWrite.ConditionalAccess`, to create the report-only policies in the tenant.
- `GroupMember.Read.All`, to confirm the break-glass group exists, is security-enabled, and has
  at least one member before any policy that excludes it is created.

`Export-CaBaseline.ps1` and `Compare-CaBaseline.ps1` ask only for `Policy.Read.All`, since they
never write to the tenant.

These scripts store no credentials anywhere, on disk or otherwise. They have no app-only sign-in
mode; every run is an interactive, delegated sign-in tied to the person running the script and
the role assigned to their account.

## Quick start

Run these from PowerShell 7, in order:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
.\Import-CaPolicyPack.ps1 -TenantId '<tenant-id-or-verified-domain>' -BreakGlassGroupId '<break-glass-group-object-id>' -WhatIf
.\Import-CaPolicyPack.ps1 -TenantId '<tenant-id-or-verified-domain>' -BreakGlassGroupId '<break-glass-group-object-id>' -Apply
.\Export-CaBaseline.ps1
.\Compare-CaBaseline.ps1
```

The first `-WhatIf` run makes no changes; it shows what would be created. The `-Apply` run
creates the report-only policies in the tenant; on its own it imports six templates, since CA007
and CA008 need an extra switch each. Add `-IncludeP2` for CA007 and `-IncludePhishingResistant`
for CA008 to import all eight. `Export-CaBaseline.ps1` writes the current tenant policies to
local files so you have a record before and after. `Compare-CaBaseline.ps1` checks the templates
against the live tenant (or an export folder) and reports whether each one is missing, matches,
differs, is still report-only, or has been enabled.

## What happens when you run Import

`Import-CaPolicyPack.ps1` runs five checks before it writes anything. If any check fails, the
script stops and makes zero writes:

1. Every template to be imported parses as valid JSON and passes the policy schema.
2. Every template's state is report-only. No parameter on this script can change a template to
   an enforced state.
3. No placeholder (such as `{{BREAK_GLASS_GROUP_ID}}`) is left unresolved after substitution.
4. The break-glass group exists, is security-enabled, and has at least one member.
5. Any named location a template references actually exists in the tenant.

If a template to be imported has the same display name (matched case-insensitively) as a policy
already in the tenant, the import skips that template and prints a warning rather than creating
a duplicate.

## Turning policies on

The templates in this pack arrive report-only on purpose. Moving a policy from report-only to
enforced, in what order, and how long to wait at each step, is covered in
[`DEPLOYMENT-ORDER.md`](DEPLOYMENT-ORDER.md).

## Licence

Released under the [MIT License](LICENSE).

## No warranty

This pack is provided as-is, without any warranty of any kind, express
or implied. The templates and scripts in this pack are a starting point for configuring
Conditional Access; they do not make a tenant secure, and they do not make a tenant compliant
with any regulation, framework, or contract. The operator is responsible for reviewing every policy
in report-only mode, for understanding what each policy does before enabling it, and for the
consequences of enabling it in their own tenant. The seller provides no support and accepts no
liability for any outcome of using this pack.
