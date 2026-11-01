#Requires -Version 7.0
<#
    CaPack.GraphRead.ps1

    Read-only Microsoft Graph helpers for Export-CaBaseline.ps1 and Compare-CaBaseline.ps1.
    Dot-sourced by those scripts alongside CaPack.Common.ps1, whose Invoke-CaPackGraphGet does
    the actual paging and retry work; the functions here are thin, read-only wrappers around it
    for the three collections this pack reads. This file does not import Microsoft.Graph.Authentication
    itself; PowerShell loads that module automatically the first time one of its cmdlets
    (Connect-MgGraph, Get-MgContext) is called, as long as it is installed.

    New for this product; not adapted from securityoak-drift.
#>

Set-StrictMode -Version Latest

function Connect-CaPackGraphReadOnly {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph with the single read-only scope the export and comparison
        scripts need.
    .DESCRIPTION
        Reuses an existing Microsoft Graph session when Get-MgContext already shows the
        Policy.Read.All scope; otherwise calls Connect-MgGraph -Scopes Policy.Read.All. Always
        delegated, interactive sign-in; there is no app-only path.
    .OUTPUTS
        System.Boolean. True when this call made a new connection, so the caller knows to
        disconnect in a finally block; false when an existing session was reused and the
        caller should leave it connected.
    .NOTES
        Requires the Microsoft.Graph.Authentication module to be installed. Scope requested:
        Policy.Read.All only.
    .EXAMPLE
        $connectedHere = Connect-CaPackGraphReadOnly
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $context = Get-MgContext
    if ($context -and $context.Scopes -contains 'Policy.Read.All') {
        Write-Verbose 'Reusing an existing Microsoft Graph session that already has Policy.Read.All.'
        return $false
    }
    Connect-MgGraph -Scopes 'Policy.Read.All' -ContextScope Process -NoWelcome
    $true
}

function Get-CaPackPolicyList {
    <#
    .SYNOPSIS
        Returns every Conditional Access policy in the tenant.
    .DESCRIPTION
        Calls Invoke-CaPackGraphGet against /identity/conditionalAccess/policies, which pages
        through @odata.nextLink and retries on throttling and transient network errors.
    .OUTPUTS
        System.Object[]
    .NOTES
        Requires Policy.Read.All and an existing Microsoft Graph session.
    .EXAMPLE
        Get-CaPackPolicyList
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/policies'
}

function Get-CaPackNamedLocationList {
    <#
    .SYNOPSIS
        Returns every named location in the tenant.
    .DESCRIPTION
        Calls Invoke-CaPackGraphGet against /identity/conditionalAccess/namedLocations, which
        pages through @odata.nextLink and retries on throttling and transient network errors.
    .OUTPUTS
        System.Object[]
    .NOTES
        Requires Policy.Read.All and an existing Microsoft Graph session.
    .EXAMPLE
        Get-CaPackNamedLocationList
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/namedLocations'
}

function Get-CaPackAuthenticationStrengthList {
    <#
    .SYNOPSIS
        Returns every authentication strength policy in the tenant, built in and custom.
    .DESCRIPTION
        Calls Invoke-CaPackGraphGet against /policies/authenticationStrengthPolicies, which
        pages through @odata.nextLink and retries on throttling and transient network errors.
    .OUTPUTS
        System.Object[]
    .NOTES
        Requires Policy.Read.All and an existing Microsoft Graph session.
    .EXAMPLE
        Get-CaPackAuthenticationStrengthList
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    Invoke-CaPackGraphGet -Uri '/policies/authenticationStrengthPolicies'
}
