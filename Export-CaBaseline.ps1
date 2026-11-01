#Requires -Version 7.0
<#
.SYNOPSIS
    Exports a read-only snapshot of a tenant's Conditional Access policies, named locations,
    and authentication strength policies.
.DESCRIPTION
    Connects to Microsoft Graph with the Policy.Read.All scope only, reads every Conditional
    Access policy, named location, and authentication strength policy, and writes them to a
    local folder as one JSON file per policy under a policies subfolder, one namedLocations.json,
    one authenticationStrengths.json, and a small export.json summary (tenant id, timestamp,
    item counts, script version; never an account name or a token). Every file is written with
    the stable, sorted-key JSON the rest of this pack uses for diffing, so two exports taken
    moments apart produce byte-identical files when nothing changed. Makes no change to the
    tenant.
.PARAMETER OutputPath
    Folder to write the export into. Defaults to CaBaseline-<yyyyMMdd-HHmm> under the current
    directory. Created if it does not already exist.
.OUTPUTS
    PSCustomObject with OutputPath, PolicyCount, NamedLocationCount, and
    AuthenticationStrengthCount.
.NOTES
    Permissions: Policy.Read.All (delegated), requested by Connect-CaPackGraphReadOnly.
    Requires the Microsoft.Graph.Authentication module to be installed; PowerShell loads it
    automatically the first time Connect-MgGraph is called.

    The exported folder contains tenant-specific data. Do not commit it to source control or
    share it outside the tenant it was captured from; CaBaseline-* is already in .gitignore.

    Author: Sec Oak
.EXAMPLE
    .\Export-CaBaseline.ps1

    Exports the signed-in tenant's Conditional Access baseline into a new
    CaBaseline-<timestamp> folder under the current directory.
.EXAMPLE
    .\Export-CaBaseline.ps1 -OutputPath C:\Baselines\before-rollout

    Exports into a specific folder, for example right before changing any policy state.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = (Join-Path -Path (Get-Location).Path -ChildPath ('CaBaseline-' + (Get-Date).ToString('yyyyMMdd-HHmm')))
)

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'src\CaPack.Common.ps1')
. (Join-Path $PSScriptRoot 'src\CaPack.GraphRead.ps1')

function Get-CaPackSafeFileName {
    <#
    .SYNOPSIS
        Turns a policy display name into a safe file name component.
    .DESCRIPTION
        Replaces every character Windows disallows in a file name with an underscore, trims
        trailing dots and spaces (also disallowed at the end of a Windows file name), and falls
        back to the literal text "policy" when nothing usable is left, for example an empty
        display name or one made entirely of disallowed characters. Long names are truncated to
        150 characters so the full path, including the policies folder and the .json extension,
        stays comfortably under the Windows path length limit. The caller is responsible for
        making the result unique among sibling files when two display names sanitise to the
        same text.
    .PARAMETER DisplayName
        The policy display name to sanitise.
    .OUTPUTS
        System.String
    .NOTES
        Internal helper, new for this product.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$DisplayName
    )
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = [System.Text.StringBuilder]::new()
    $hasValidCharacter = $false
    foreach ($character in $DisplayName.ToCharArray()) {
        if ($invalidChars -contains $character) {
            [void]$builder.Append('_')
        }
        else {
            $hasValidCharacter = $true
            [void]$builder.Append($character)
        }
    }
    $safe = $builder.ToString().Trim().TrimEnd('.', ' ')
    if (-not $hasValidCharacter -or [string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'policy'
    }
    if ($safe.Length -gt 150) {
        $safe = $safe.Substring(0, 150)
    }
    $safe
}

$connectedHere = $false
try {
    $connectedHere = Connect-CaPackGraphReadOnly

    $policies = Get-CaPackPolicyList
    $namedLocations = Get-CaPackNamedLocationList
    $authenticationStrengths = Get-CaPackAuthenticationStrengthList
    $context = Get-MgContext

    $policiesPath = Join-Path $OutputPath 'policies'
    New-Item -Path $policiesPath -ItemType Directory -Force | Out-Null

    Write-Warning "The folder '$OutputPath' now contains tenant data. Do not commit it to source control or share it outside the tenant it was captured from."

    $usedFileNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($policy in $policies) {
        $displayName = [string](Get-CaPackMember -InputObject $policy -Name 'displayName')
        $baseName = Get-CaPackSafeFileName -DisplayName $displayName
        $fileName = $baseName
        $suffix = 1
        while (-not $usedFileNames.Add($fileName)) {
            $suffix++
            $fileName = "$baseName-$suffix"
        }
        $policyFilePath = Join-Path $policiesPath "$fileName.json"
        Set-Content -Path $policyFilePath -Value (ConvertTo-CaPackStableJson -InputObject $policy) -NoNewline -Encoding utf8
    }

    Set-Content -Path (Join-Path $OutputPath 'namedLocations.json') -Value (ConvertTo-CaPackStableJson -InputObject $namedLocations) -NoNewline -Encoding utf8
    Set-Content -Path (Join-Path $OutputPath 'authenticationStrengths.json') -Value (ConvertTo-CaPackStableJson -InputObject $authenticationStrengths) -NoNewline -Encoding utf8

    $exportSummary = [ordered]@{
        tenantId                    = if ($context) { $context.TenantId } else { $null }
        timestamp                   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        policyCount                 = $policies.Count
        namedLocationCount          = $namedLocations.Count
        authenticationStrengthCount = $authenticationStrengths.Count
        scriptVersion               = '1.0.0'
    }
    Set-Content -Path (Join-Path $OutputPath 'export.json') -Value (ConvertTo-CaPackStableJson -InputObject $exportSummary) -NoNewline -Encoding utf8

    [pscustomobject]@{
        OutputPath                  = $OutputPath
        PolicyCount                 = $policies.Count
        NamedLocationCount          = $namedLocations.Count
        AuthenticationStrengthCount = $authenticationStrengths.Count
    }
}
finally {
    if ($connectedHere) {
        Disconnect-MgGraph | Out-Null
    }
}
