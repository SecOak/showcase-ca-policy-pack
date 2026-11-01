#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.41.0' }
<#
.SYNOPSIS
    Creates this pack's Conditional Access policies in a Microsoft Entra tenant, report-only.
.DESCRIPTION
    Runs in three phases: gather, plan, apply.

    Gather reads manifest.json under TemplatePath, drops any template whose manifest entry
    names a requiresSwitch that was not supplied (-IncludeP2 or -IncludePhishingResistant), and
    applies -Include and -Exclude by template id. For every remaining template it validates the
    raw file against schema\conditionalAccessTemplate.schema.json, substitutes double-brace
    placeholder tokens (BREAK_GLASS_GROUP_ID always; TRUSTED_LOCATION_ID only for a template
    that contains it, in which case -TrustedLocationId becomes mandatory for that template),
    and confirms no double brace is left in the result. It also confirms the break-glass group
    exists, is
    security-enabled, and has at least one member, and, when any template needed it, that the
    trusted location exists. Once substituted, every policy's state is forced to
    enabledForReportingButNotEnforced regardless of what the template file said; no parameter
    changes this.

    Any gather check that fails stops the script before anything is written to the tenant.

    Plan lists the existing Conditional Access policies and marks each remaining template
    Create, or Skip (with a warning) when a policy with the same display name, compared
    case-insensitively, already exists.

    Apply runs only when -Apply is supplied and -WhatIf is not. It creates each planned policy
    in turn, confirming through ShouldProcess (SupportsShouldProcess, ConfirmImpact High). If
    creating a policy fails, that policy is reported Failed and the run stops: every remaining
    Create item is reported NotAttempted rather than the stale Planned value from the plan, so
    the output never claims a policy is still planned when it was in fact never tried, and a
    Write-Error after the loop lists the display name and id of every policy this run did
    create before the failure. Policies already created before the failure stay created; this
    script never deletes or rolls back what it already wrote.

    Without -Apply, or with -WhatIf, the plan is printed and nothing is written.
.PARAMETER TenantId
    The tenant's directory id (GUID) or a verified domain, for example
    contoso.onmicrosoft.com. Mandatory, and passed to Connect-MgGraph. An existing Microsoft
    Graph session is reused only when it is already delegated and already connected to this
    tenant; any other session, including an app-only session or one connected to a different
    tenant, is disconnected and a fresh sign-in to this tenant follows, so this script can
    never run against the wrong tenant by reusing a stray session.
.PARAMETER BreakGlassGroupId
    Object id of the break-glass group to exclude from every policy. Mandatory. Must exist, be
    security-enabled, and have at least one member.
.PARAMETER TemplatePath
    Root folder containing manifest.json, the templates folder, and the schema folder. Defaults
    to the folder containing this script.
.PARAMETER Include
    Template ids (for example CA001) to include. When supplied, only these templates are
    considered. Matched case-insensitively.
.PARAMETER Exclude
    Template ids to leave out, applied after -Include. Matched case-insensitively.
.PARAMETER TrustedLocationId
    Object id of a Conditional Access named location. Required only when a selected template
    contains the {{TRUSTED_LOCATION_ID}} placeholder; the gather phase fails with a clear
    message if that template is selected and this is not supplied, or if the id does not match
    an existing named location.
.PARAMETER IncludeP2
    Includes CA007 (Block high-risk sign-ins), which the manifest marks as requiring an Entra ID
    P2 licence.
.PARAMETER IncludePhishingResistant
    Includes CA008 (Phishing-resistant MFA for admins). Admins must register a FIDO2 key or
    Windows Hello for Business before this is enforced later; this switch only creates the
    report-only policy.
.PARAMETER Apply
    Writes the planned policies to the tenant. Without this switch, the script only prints the
    plan.
.OUTPUTS
    System.Object. One object per selected template, with Name, Action (Create, Skip), Result
    (Planned, Created, Skipped, Failed, NotAttempted), and PolicyId. NotAttempted marks a
    Create item that was never tried because an earlier one in this run failed.
.EXAMPLE
    Import-CaPolicyPack.ps1 -TenantId 'contoso.onmicrosoft.com' -BreakGlassGroupId '11111111-1111-1111-1111-111111111111'
    Prints the plan for the six templates that need no extra licence switch. Writes nothing.
.EXAMPLE
    Import-CaPolicyPack.ps1 -TenantId $tenantId -BreakGlassGroupId $breakGlassId -Apply
    Creates every one of those six policies that does not already exist, prompting to confirm
    each one before it is created.
.EXAMPLE
    Import-CaPolicyPack.ps1 -TenantId $tenantId -BreakGlassGroupId $breakGlassId -IncludeP2 -IncludePhishingResistant -Apply -Confirm:$false
    Creates all eight policies, including the two that require extra licensing switches,
    without prompting for each one.
.NOTES
    Author: Sec Oak
    Date: 2026-10-01
    Required module: Microsoft.Graph.Authentication 2.41.0 or later
    Required scopes: Policy.Read.All, Policy.ReadWrite.ConditionalAccess, GroupMember.Read.All
    No secrets, no tokens on disk, no app-only sign-in path. You run this against their own
    tenant; nothing here phones home.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}|([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,})$')]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$BreakGlassGroupId,

    [Parameter()]
    [string]$TemplatePath = $PSScriptRoot,

    [Parameter()]
    [string[]]$Include,

    [Parameter()]
    [string[]]$Exclude,

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TrustedLocationId,

    [Parameter()]
    [switch]$IncludeP2,

    [Parameter()]
    [switch]$IncludePhishingResistant,

    [Parameter()]
    [switch]$Apply
)

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'src' 'CaPack.Common.ps1')
if (-not (Get-Command -Name 'Connect-CaPackGraph' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'src' 'CaPack.Graph.ps1')
}

$requiredScopes = @('Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'GroupMember.Read.All')
$connectedHere = $false

try {
    # ---- Gather: resolve the template set ----
    $manifestPath = Join-Path $TemplatePath 'manifest.json'
    if (-not (Test-Path -Path $manifestPath)) {
        throw "Manifest file not found at '$manifestPath'."
    }
    $schemaPath = Join-Path $TemplatePath 'schema' 'conditionalAccessTemplate.schema.json'
    if (-not (Test-Path -Path $schemaPath)) {
        throw "Schema file not found at '$schemaPath'."
    }

    $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
    $allIds = @($manifest.templates | ForEach-Object { $_.id })

    if ($Include) {
        $unknownIds = @($Include | Where-Object { $allIds -notcontains $_ })
        if ($unknownIds.Count -gt 0) {
            throw "Unknown template id(s) in -Include: $($unknownIds -join ', ')."
        }
    }

    $entries = @($manifest.templates)
    if ($Include) {
        $entries = @($entries | Where-Object { $Include -contains $_.id })
    }
    if ($Exclude) {
        $entries = @($entries | Where-Object { $Exclude -notcontains $_.id })
    }

    # A gated id that was explicitly named in -Include but whose switch was not supplied is a
    # terminating error, not a silent drop: the caller asked for it by id and deserves to know
    # why it is missing. A gated id that was never named in -Include (the default full run, or
    # one where it was left out on purpose) is still dropped silently; that is normal, expected
    # filtering, not a mistake to report.
    foreach ($entry in $entries) {
        $gateSatisfied = switch ($entry.requiresSwitch) {
            'IncludeP2' { $IncludeP2.IsPresent }
            'IncludePhishingResistant' { $IncludePhishingResistant.IsPresent }
            default { $true }
        }
        if (-not $gateSatisfied -and $Include -and ($Include -contains $entry.id)) {
            throw "Template '$($entry.id)' requires -$($entry.requiresSwitch); supply it to include '$($entry.id)'."
        }
    }

    $entries = @($entries | Where-Object {
            switch ($_.requiresSwitch) {
                'IncludeP2' { $IncludeP2.IsPresent }
                'IncludePhishingResistant' { $IncludePhishingResistant.IsPresent }
                default { $true }
            }
        })
    $entries = @($entries | Sort-Object -Property order)

    if ($entries.Count -eq 0) {
        Write-Warning 'No templates matched the given filters; nothing to do.'
        return
    }

    # ---- Gather: connect and validate the break-glass group and, if needed, the location ----
    $connectedHere = Connect-CaPackGraph -Scopes $requiredScopes -TenantId $TenantId

    $breakGlassGroup = Get-CaPackGroup -GroupId $BreakGlassGroupId
    if (-not $breakGlassGroup) {
        throw "Break-glass group '$BreakGlassGroupId' was not found."
    }
    if (-not $breakGlassGroup.securityEnabled) {
        throw "Break-glass group '$BreakGlassGroupId' is not security-enabled."
    }
    $breakGlassMemberCount = Get-CaPackGroupMemberCount -GroupId $BreakGlassGroupId
    if ($breakGlassMemberCount -le 0) {
        throw "Break-glass group '$BreakGlassGroupId' has no members."
    }

    $placeholderValues = @{ BREAK_GLASS_GROUP_ID = $BreakGlassGroupId }
    $namedLocationChecked = $false

    # ---- Gather: load, validate, and substitute each template ----
    $prepared = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        $relativeFile = $entry.file -replace '/', [System.IO.Path]::DirectorySeparatorChar
        $templateFile = Join-Path $TemplatePath $relativeFile
        if (-not (Test-Path -Path $templateFile)) {
            throw "Template file '$templateFile' listed in the manifest for '$($entry.id)' was not found."
        }
        $rawJson = Get-Content -Path $templateFile -Raw

        if (-not (Test-Json -Json $rawJson -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
            throw "Template '$($entry.id)' at '$templateFile' failed schema validation."
        }

        $tokens = Test-CaPackPlaceholder -Json $rawJson
        if ($tokens -contains 'TRUSTED_LOCATION_ID') {
            if ([string]::IsNullOrWhiteSpace($TrustedLocationId)) {
                throw "Template '$($entry.id)' references {{TRUSTED_LOCATION_ID}}; supply -TrustedLocationId."
            }
            if (-not $namedLocationChecked) {
                $namedLocation = Get-CaPackNamedLocation -NamedLocationId $TrustedLocationId
                if (-not $namedLocation) {
                    throw "Named location '$TrustedLocationId' was not found."
                }
                $namedLocationChecked = $true
            }
            $placeholderValues['TRUSTED_LOCATION_ID'] = $TrustedLocationId
        }

        $expandedJson = Expand-CaPackPlaceholder -Json $rawJson -Values $placeholderValues
        if ($expandedJson.Contains('{{')) {
            throw "Template '$($entry.id)' still contains an unresolved placeholder token after substitution."
        }

        $policyObject = $expandedJson | ConvertFrom-Json
        $policyObject.state = 'enabledForReportingButNotEnforced'

        $prepared.Add([pscustomobject]@{
                Id          = $entry.id
                DisplayName = $policyObject.displayName
                Policy      = $policyObject
            })
    }

    # ---- Plan ----
    $existingPolicies = @(Get-CaPackPolicies)
    $existingByName = @{}
    foreach ($policy in $existingPolicies) {
        if ($policy.displayName) {
            $existingByName[$policy.displayName.ToLowerInvariant()] = $policy
        }
    }

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $prepared) {
        $existing = $existingByName[$item.DisplayName.ToLowerInvariant()]
        if ($existing) {
            Write-Warning "Skipping '$($item.DisplayName)': a policy with that display name already exists."
            $plan.Add([pscustomobject][ordered]@{
                    Name     = $item.DisplayName
                    Action   = 'Skip'
                    Result   = 'Skipped'
                    PolicyId = $existing.id
                    Policy   = $item.Policy
                })
        }
        else {
            $plan.Add([pscustomobject][ordered]@{
                    Name     = $item.DisplayName
                    Action   = 'Create'
                    Result   = 'Planned'
                    PolicyId = $null
                    Policy   = $item.Policy
                })
        }
    }

    if (-not $Apply -or $WhatIfPreference) {
        $plan | Select-Object -Property Name, Action, Result, PolicyId
        return
    }

    # ---- Apply ----
    $results = [System.Collections.Generic.List[object]]::new()
    $stopped = $false
    foreach ($item in $plan) {
        if ($item.Action -ne 'Create') {
            $results.Add([pscustomobject][ordered]@{ Name = $item.Name; Action = $item.Action; Result = $item.Result; PolicyId = $item.PolicyId })
            continue
        }

        if ($stopped) {
            # An earlier item in this run already failed. This one was never attempted, so it
            # must not be reported with the plan's stale 'Planned' value, which would read as
            # though it is still waiting to run.
            $results.Add([pscustomobject][ordered]@{ Name = $item.Name; Action = 'Create'; Result = 'NotAttempted'; PolicyId = $null })
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($item.Name) (tenant $TenantId)", 'Create conditional access policy')) {
            try {
                $created = New-CaPackPolicy -Policy $item.Policy
                $results.Add([pscustomobject][ordered]@{ Name = $item.Name; Action = 'Create'; Result = 'Created'; PolicyId = $created.id })
            }
            catch {
                Write-Warning "Failed to create '$($item.Name)': $($_.Exception.Message)"
                $results.Add([pscustomobject][ordered]@{ Name = $item.Name; Action = 'Create'; Result = 'Failed'; PolicyId = $null })
                $stopped = $true
            }
        }
        else {
            $results.Add([pscustomobject][ordered]@{ Name = $item.Name; Action = 'Create'; Result = 'Planned'; PolicyId = $null })
        }
    }

    # The result table goes out before the error so it is not lost when the
    # caller runs with -ErrorAction Stop.
    $results

    if ($stopped) {
        $createdDescriptions = @($results | Where-Object { $_.Result -eq 'Created' } | ForEach-Object { "$($_.Name) ($($_.PolicyId))" })
        $createdSummary = if ($createdDescriptions.Count -gt 0) { $createdDescriptions -join ', ' } else { 'none' }
        Write-Error "Import stopped after a policy failed to create. Policies already created in this run: $createdSummary."
    }
}
finally {
    if ($connectedHere) {
        Disconnect-CaPackGraph
    }
}
