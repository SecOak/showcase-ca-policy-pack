#Requires -Version 7.0
<#
.SYNOPSIS
    Compares a tenant's Conditional Access policies against this pack's templates.
.DESCRIPTION
    Reads every template under -TemplatePath and matches it, by display name (case
    insensitive), to a Conditional Access policy read either from a baseline export folder
    (-BaselinePath, as written by Export-CaBaseline.ps1) or, when -BaselinePath is omitted,
    directly from the live tenant with the Policy.Read.All scope. Before comparing, the
    break-glass group id (and, when given, the trusted location id) are swapped back into the
    {{BREAK_GLASS_GROUP_ID}} / {{TRUSTED_LOCATION_ID}} tokens the templates use, so a policy
    that was imported unchanged compares as a match rather than a false difference. Volatile
    fields (id, createdDateTime, modifiedDateTime, templateId, and every @odata field) are
    stripped from both sides before comparing, and arrays of simple values are compared as
    sets, so reordering a role or application list is never reported as a difference.

    The policy's own state field is handled separately from every other field, because turning
    a policy from report-only to enabled is the normal, expected outcome of following
    DEPLOYMENT-ORDER.md, not a problem to flag the same way a changed condition or control
    would be:

      - Missing     no live policy with that display name was found.
      - Matches     every field other than state is identical, and the live state is the same
                    as the template's own state value. Every template in this pack ships with
                    state enabledForReportingButNotEnforced, so in practice this is the
                    unmodified-import case.
      - Enabled     every field other than state is identical, and the live state is enabled:
                    the policy was turned on as recommended.
      - Disabled    every field other than state is identical, and the live state is disabled:
                    the policy exists in the tenant but is turned off entirely, worth a second
                    look since it enforces nothing and reports nothing.
      - ReportOnly  every field other than state is identical, and the live state is some
                    other, unexpected value: not the template's own state, not enabled, and
                    not disabled.
      - Differs     some field other than state is different. Path, Expected, and Actual
                    describe the first such difference, in the order Compare-CaPackValue finds
                    it; there may be more than one.

    A live policy that does not match any template's display name is also returned, with
    Status NotInPack, so a policy added outside this pack is visible rather than silently
    ignored. When two live policies share the same display name, only the first is matched
    against a template; every later one is also returned with Status NotInPack and Path
    displayName, naming the duplicate in Actual, so a naming collision is visible rather than
    silently dropped.

    Microsoft Graph expands some navigation properties into a full object plus a sibling
    "<property>@odata.context" key, for example grantControls.authenticationStrength; every
    template in this pack references such a property by id alone. Before comparing, the live
    policy's authenticationStrength is reduced to its id and every @odata.context sibling key
    is dropped from both sides, so an authentication strength policy referenced by id compares
    as a match rather than a false difference.
.PARAMETER TemplatePath
    Folder containing the template JSON files to compare against. Defaults to templates.
.PARAMETER BaselinePath
    Folder previously written by Export-CaBaseline.ps1 (its policies subfolder is read).
    When omitted, policies are read from the live tenant instead, which requires signing in
    with Policy.Read.All.
.PARAMETER BreakGlassGroupId
    The tenant's real break-glass group id, swapped back to the {{BREAK_GLASS_GROUP_ID}}
    placeholder before comparing. Required: every template excludes this group, so without it
    every template would be reported as differing.
.PARAMETER TrustedLocationId
    The tenant's real trusted location id, swapped back to the {{TRUSTED_LOCATION_ID}}
    placeholder before comparing, for templates that reference a trusted location. Optional;
    omit it if no template in use references a trusted location.
.PARAMETER CsvPath
    When given, also writes the result objects to this path with Export-Csv.
.OUTPUTS
    PSCustomObject with Template, Status, State, Path, Expected, and Actual, one per template
    plus one per unmatched live policy.
.NOTES
    Permissions: Policy.Read.All (delegated), requested by Connect-CaPackGraphReadOnly, only
    when -BaselinePath is omitted.

    This script always exits 0 when it completes normally. A Differs or Missing result is
    data describing the tenant, not a script failure, so it is never surfaced as a non-zero
    exit code; only a genuine execution problem, such as an unreadable template file or a
    failed Graph connection, throws and exits non-zero.

    Author: Sec Oak
.EXAMPLE
    .\Compare-CaBaseline.ps1 -BreakGlassGroupId '11111111-1111-1111-1111-111111111111'

    Signs in to the live tenant and compares it against the templates folder.
.EXAMPLE
    .\Compare-CaBaseline.ps1 -BaselinePath .\CaBaseline-20261001-0900 -BreakGlassGroupId '11111111-1111-1111-1111-111111111111' -CsvPath .\drift.csv

    Compares a previously captured baseline export against the templates, and also writes the
    result to a CSV file.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$TemplatePath = 'templates',

    [Parameter()]
    [string]$BaselinePath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$BreakGlassGroupId,

    [Parameter()]
    [string]$TrustedLocationId,

    [Parameter()]
    [string]$CsvPath
)

Set-StrictMode -Version Latest

if ($TrustedLocationId -and $TrustedLocationId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw "TrustedLocationId '$TrustedLocationId' is not a GUID."
}

. (Join-Path $PSScriptRoot 'src\CaPack.Common.ps1')
. (Join-Path $PSScriptRoot 'src\CaPack.GraphRead.ps1')

function ConvertTo-CaPackPlaceholderText {
    <#
    .SYNOPSIS
        Replaces every string value equal to a known tenant identifier with its template
        placeholder token, recursively.
    .DESCRIPTION
        A live policy read back from the tenant carries real identifiers, such as the
        break-glass group id, where its template carries a {{PLACEHOLDER}} token. Comparing the
        two directly would always report a difference at that field even when nothing
        meaningful changed. This walks the live policy and swaps every string value that
        matches a known identifier, compared case-insensitively, for the token text the
        template uses, so the two sides line up before normalising and comparing.
    .PARAMETER Value
        The value to walk: an object, array, or scalar read from Microsoft Graph.
    .PARAMETER Map
        A hashtable from known identifier text to placeholder token text, for example
        @{ '11111111-1111-1111-1111-111111111111' = '{{BREAK_GLASS_GROUP_ID}}' }.
    .OUTPUTS
        System.Object
    .NOTES
        Internal helper, new for this product.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Map
    )
    if ($null -eq $Value) {
        return $Value
    }
    if ($Value -is [string]) {
        foreach ($key in $Map.Keys) {
            if ([string]::Equals($Value, $key, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $Map[$key]
            }
        }
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result["$key"] = ConvertTo-CaPackPlaceholderText -Value $Value[$key] -Map $Map
        }
        return $result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-CaPackPlaceholderText -Value $property.Value -Map $Map
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($element in $Value) {
            $list.Add((ConvertTo-CaPackPlaceholderText -Value $element -Map $Map))
        }
        return , $list.ToArray()
    }
    $Value
}

function ConvertTo-CaPackDisplayValue {
    <#
    .SYNOPSIS
        Renders a value for the Expected / Actual columns as a single line of text.
    .DESCRIPTION
        A scalar is returned as-is; anything else (an object or array pulled out of a policy
        at the point two sides first differ) is rendered as compact, stable JSON so it reads
        sensibly both on screen and in a CSV cell.
    .PARAMETER Value
        The value to render.
    .OUTPUTS
        System.Object
    .NOTES
        Internal helper, new for this product.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        $Value
    )
    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [System.ValueType]) {
        return $Value
    }
    ConvertTo-CaPackStableJson -InputObject $Value
}

function Remove-CaPackODataProperty {
    <#
    .SYNOPSIS
        Recursively removes any property whose name contains "@odata." anywhere, not only at
        the start.
    .DESCRIPTION
        ConvertTo-CaPackNormalizedValue (src\CaPack.Common.ps1, shared with the rest of this
        pack) only drops a property whose name starts with @odata., which misses a sibling key
        Microsoft Graph adds next to an expanded navigation property, for example
        authenticationStrength@odata.context sitting next to authenticationStrength under
        grantControls. This walks a value the same way ConvertTo-CaPackPlaceholderText does and
        drops every property whose name contains @odata. (compared case-insensitively) at any
        depth, so both sides of a comparison are free of these Graph-only artifacts before
        normalising, without changing the shared helper other scripts in this pack rely on.
    .PARAMETER Value
        The value to walk: an object, array, or scalar.
    .OUTPUTS
        System.Object
    .NOTES
        Internal helper, new for this product.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        $Value
    )
    if ($null -eq $Value) {
        return $Value
    }
    if ($Value -is [string]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            if ("$key".Contains('@odata.', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $result["$key"] = Remove-CaPackODataProperty -Value $Value[$key]
        }
        return $result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name.Contains('@odata.', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $result[$property.Name] = Remove-CaPackODataProperty -Value $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($element in $Value) {
            $list.Add((Remove-CaPackODataProperty -Value $element))
        }
        return , $list.ToArray()
    }
    $Value
}

function ConvertTo-CaPackAuthenticationStrengthReference {
    <#
    .SYNOPSIS
        Reduces a live policy's grantControls.authenticationStrength to just its id, matching
        the shape every template in this pack uses.
    .DESCRIPTION
        Microsoft Graph expands grantControls.authenticationStrength into its full object
        (displayName, allowedCombinations, createdDateTime, and so on); every template in this
        pack references an authentication strength by id alone. Without this, a template that
        sets grantControls.authenticationStrength, such as CA008, would always be reported as
        Differs in production, even when the live policy references exactly the strength the
        template asks for.
    .PARAMETER Value
        The restored, placeholder-swapped live policy (an ordered hashtable tree). Values that
        are not a dictionary, or that have no grantControls.authenticationStrength.id, are
        returned unchanged.
    .OUTPUTS
        System.Object
    .NOTES
        Internal helper, new for this product.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Value
    )
    if ($Value -isnot [System.Collections.IDictionary]) {
        return $Value
    }
    if (-not $Value.Contains('grantControls')) {
        return $Value
    }
    $grantControls = $Value['grantControls']
    if ($grantControls -isnot [System.Collections.IDictionary] -or -not $grantControls.Contains('authenticationStrength')) {
        return $Value
    }
    $authenticationStrength = $grantControls['authenticationStrength']
    if ($authenticationStrength -isnot [System.Collections.IDictionary] -or -not $authenticationStrength.Contains('id')) {
        return $Value
    }
    $grantControls['authenticationStrength'] = [ordered]@{ id = $authenticationStrength['id'] }
    $Value
}

function Get-CaPackTemplateComparisonResult {
    <#
    .SYNOPSIS
        Compares one template to its matching live policy, or reports it missing.
    .DESCRIPTION
        See the script's own .DESCRIPTION for the Missing / Matches / Enabled / Disabled /
        ReportOnly / Differs rules this applies.
    .PARAMETER Template
        The parsed template object.
    .PARAMETER LivePolicy
        The matching live policy object, or $null when none was found.
    .PARAMETER TemplateName
        The template's display name, used for the Template column.
    .PARAMETER PlaceholderMap
        Passed through to ConvertTo-CaPackPlaceholderText.
    .OUTPUTS
        PSCustomObject with Template, Status, State, Path, Expected, Actual.
    .NOTES
        Internal helper, new for this product.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Template,

        [Parameter()]
        [AllowNull()]
        $LivePolicy,

        [Parameter(Mandatory)]
        [string]$TemplateName,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$PlaceholderMap
    )

    if ($null -eq $LivePolicy) {
        return [pscustomobject][ordered]@{
            Template = $TemplateName
            Status   = 'Missing'
            State    = ''
            Path     = ''
            Expected = ''
            Actual   = ''
        }
    }

    $volatileFields = @('id', 'createdDateTime', 'modifiedDateTime', 'templateId')
    $restoredLive = ConvertTo-CaPackPlaceholderText -Value $LivePolicy -Map $PlaceholderMap
    $restoredLive = ConvertTo-CaPackAuthenticationStrengthReference -Value $restoredLive
    $cleanTemplate = Remove-CaPackODataProperty -Value $Template
    $cleanLive = Remove-CaPackODataProperty -Value $restoredLive
    $normalizedTemplate = ConvertTo-CaPackNormalizedItem -Item $cleanTemplate -VolatileFields $volatileFields
    $normalizedLive = ConvertTo-CaPackNormalizedItem -Item $cleanLive -VolatileFields $volatileFields

    $templateState = [string](Get-CaPackMember -InputObject $normalizedTemplate -Name 'state')
    $liveState = [string](Get-CaPackMember -InputObject $normalizedLive -Name 'state')
    $normalizedTemplate.Remove('state')
    $normalizedLive.Remove('state')

    $changes = [System.Collections.Generic.List[object]]::new()
    Compare-CaPackValue -Path '' -Before $normalizedTemplate -After $normalizedLive -Changes $changes

    if ($changes.Count -gt 0) {
        $first = $changes[0]
        return [pscustomobject][ordered]@{
            Template = $TemplateName
            Status   = 'Differs'
            State    = $liveState
            Path     = $first.Path
            Expected = ConvertTo-CaPackDisplayValue -Value $first.Before
            Actual   = ConvertTo-CaPackDisplayValue -Value $first.After
        }
    }

    $status = switch ($liveState) {
        $templateState { 'Matches' }
        'enabled' { 'Enabled' }
        'disabled' { 'Disabled' }
        default { 'ReportOnly' }
    }

    [pscustomobject][ordered]@{
        Template = $TemplateName
        Status   = $status
        State    = $liveState
        Path     = ''
        Expected = ''
        Actual   = ''
    }
}

function Get-CaPackNotInPackResult {
    <#
    .SYNOPSIS
        Builds the result row for a live policy that no template matches.
    .PARAMETER LivePolicy
        The unmatched live policy object.
    .OUTPUTS
        PSCustomObject with Template, Status, State, Path, Expected, Actual.
    .NOTES
        Internal helper, new for this product.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $LivePolicy
    )
    [pscustomobject][ordered]@{
        Template = [string](Get-CaPackMember -InputObject $LivePolicy -Name 'displayName')
        Status   = 'NotInPack'
        State    = [string](Get-CaPackMember -InputObject $LivePolicy -Name 'state')
        Path     = ''
        Expected = ''
        Actual   = ''
    }
}

function Get-CaPackDuplicateNameResult {
    <#
    .SYNOPSIS
        Builds the result row for a live policy whose display name duplicates another live
        policy's.
    .DESCRIPTION
        Only the first live policy with a given display name is ever matched against a
        template; every later live policy sharing that name would otherwise be dropped
        silently. This builds a NotInPack row for it instead, with Path displayName and Actual
        naming the duplicate by its id, so a tenant with two policies of the same name is never
        misrepresented as clean.
    .PARAMETER LivePolicy
        The duplicate live policy object (not the first one seen with this display name).
    .OUTPUTS
        PSCustomObject with Template, Status, State, Path, Expected, Actual.
    .NOTES
        Internal helper, new for this product.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $LivePolicy
    )
    $name = [string](Get-CaPackMember -InputObject $LivePolicy -Name 'displayName')
    $id = [string](Get-CaPackMember -InputObject $LivePolicy -Name 'id')
    [pscustomobject][ordered]@{
        Template = $name
        Status   = 'NotInPack'
        State    = [string](Get-CaPackMember -InputObject $LivePolicy -Name 'state')
        Path     = 'displayName'
        Expected = ''
        Actual   = "Duplicate display name '$name' (id $id)"
    }
}

$placeholderMap = [ordered]@{}
$placeholderMap[$BreakGlassGroupId] = '{{BREAK_GLASS_GROUP_ID}}'
if ($TrustedLocationId) {
    $placeholderMap[$TrustedLocationId] = '{{TRUSTED_LOCATION_ID}}'
}

$templateFiles = Get-ChildItem -Path $TemplatePath -Filter '*.json' -File | Sort-Object Name

if ($BaselinePath) {
    $policyFiles = Get-ChildItem -Path (Join-Path $BaselinePath 'policies') -Filter '*.json' -File
    $livePolicies = @(foreach ($file in $policyFiles) { Get-Content -Path $file.FullName -Raw | ConvertFrom-Json })
}
else {
    $connectedHere = Connect-CaPackGraphReadOnly
    try {
        $livePolicies = Get-CaPackPolicyList
    }
    finally {
        if ($connectedHere) {
            Disconnect-MgGraph | Out-Null
        }
    }
}

$liveByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$duplicateLivePolicies = [System.Collections.Generic.List[object]]::new()
foreach ($livePolicy in $livePolicies) {
    $name = [string](Get-CaPackMember -InputObject $livePolicy -Name 'displayName')
    if ($liveByName.ContainsKey($name)) {
        $duplicateLivePolicies.Add($livePolicy)
    }
    else {
        $liveByName[$name] = $livePolicy
    }
}

$matchedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$results = [System.Collections.Generic.List[object]]::new()

foreach ($file in $templateFiles) {
    $template = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
    $templateName = [string]$template.displayName
    $livePolicy = $null
    if ($liveByName.ContainsKey($templateName)) {
        $livePolicy = $liveByName[$templateName]
        [void]$matchedNames.Add($templateName)
    }
    $results.Add((Get-CaPackTemplateComparisonResult -Template $template -LivePolicy $livePolicy -TemplateName $templateName -PlaceholderMap $placeholderMap))
}

foreach ($name in $liveByName.Keys) {
    if (-not $matchedNames.Contains($name)) {
        $results.Add((Get-CaPackNotInPackResult -LivePolicy $liveByName[$name]))
    }
}

foreach ($duplicate in $duplicateLivePolicies) {
    $results.Add((Get-CaPackDuplicateNameResult -LivePolicy $duplicate))
}

if ($CsvPath) {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation
}

$results
