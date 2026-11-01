#Requires -Version 7.0
<#
    CaPack.Graph.ps1

    Every Microsoft Graph call made by this pack's scripts goes through one of the functions
    below. Each one wraps Invoke-MgGraphRequest, directly or through the private
    Invoke-CaPackGraphRetryable helper in this file (or, for Get-CaPackPolicies, the paging
    and retry helper in CaPack.Common.ps1), with no other logic in between, so a Pester test
    can mock any of these seven functions by name and exercise the rest of a script
    (Import-CaPolicyPack.ps1 and its siblings) without ever touching a real tenant.

    This file does not connect to Microsoft Graph on its own; Connect-CaPackGraph and
    Disconnect-CaPackGraph wrap the connect and disconnect calls, but the decision of when to
    call them, and whether to disconnect afterward, belongs to the calling script.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'CaPack.Common.ps1')

function Test-CaPackHttpNotFound {
    <#
    .SYNOPSIS
        Returns true when an exception represents a Microsoft Graph HTTP 404 response.
    .PARAMETER Exception
        The exception to inspect.
    .OUTPUTS
        System.Boolean
    .NOTES
        Internal helper, private to this file. Not one of the seven functions a caller mocks;
        it exists only so Get-CaPackGroup and Get-CaPackNamedLocation can turn a 404 into a
        plain $null return instead of a thrown error, which is easier for a caller, and for a
        Pester test, to work with than inspecting exception types.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][System.Exception]$Exception
    )
    if ($null -eq $Exception) { return $false }
    $statusCode = 0
    if ($Exception.PSObject.Properties['StatusCode'] -and $Exception.StatusCode) {
        $statusCode = [int]$Exception.StatusCode
    }
    elseif ($Exception.PSObject.Properties['Response'] -and $Exception.Response -and
        $Exception.Response.PSObject.Properties['StatusCode']) {
        $statusCode = [int]$Exception.Response.StatusCode
    }
    elseif ($Exception.Message -match '\b404\b') {
        $statusCode = 404
    }
    $statusCode -eq 404
}

function Connect-CaPackGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph with delegated authentication in a specific tenant,
        reusing an existing session only when it already matches.
    .DESCRIPTION
        Reads the current session with Get-MgContext. An existing session is reused, doing
        nothing and returning false, only when all three hold: it is delegated
        (AuthType -eq 'Delegated'), it is already connected to TenantId, and its Scopes already
        include every scope in Scopes. An app-only session, a session connected to a different
        tenant, or one missing a required scope is never reused: it is disconnected first, so
        this call can never run a Graph request against the wrong tenant or over a session it
        did not start, and a fresh Connect-MgGraph -TenantId follows. Returns true whenever
        this call connected (or reconnected) the session.
    .PARAMETER Scopes
        The delegated scopes the caller needs, for example Policy.Read.All.
    .PARAMETER TenantId
        The tenant's directory id (GUID) or a verified domain, for example
        contoso.onmicrosoft.com. Required so a stray session from another tenant is never
        reused silently.
    .OUTPUTS
        System.Boolean. True when this call connected or reconnected a session; false when an
        existing session already matched every requirement and was reused.
    .EXAMPLE
        Connect-CaPackGraph -Scopes 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess' -TenantId $tenantId
    .NOTES
        No secrets, tokens, or app-only sign-in path. ContextScope Process keeps the session
        from leaking into other PowerShell processes on the machine.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string[]]$Scopes,
        [Parameter(Mandatory)][string]$TenantId
    )
    $context = Get-MgContext
    if ($context -and $context.Scopes) {
        $haveEveryScope = $true
        foreach ($scope in $Scopes) {
            if (@($context.Scopes) -notcontains $scope) {
                $haveEveryScope = $false
                break
            }
        }
        $isDelegated = $context.AuthType -eq 'Delegated'
        $isSameTenant = $context.TenantId -and [string]::Equals($context.TenantId, $TenantId, [System.StringComparison]::OrdinalIgnoreCase)
        if ($haveEveryScope -and $isDelegated -and $isSameTenant) {
            Write-Verbose 'Reusing the existing Microsoft Graph session; it is delegated, in the required tenant, and already has every required scope.'
            return $false
        }
        Write-Verbose 'Disconnecting the existing Microsoft Graph session: it is not delegated, is not in the required tenant, or is missing a required scope.'
        $null = Disconnect-MgGraph
    }
    Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -ContextScope Process -NoWelcome -ErrorAction Stop
    $true
}

function Invoke-CaPackGraphRetryable {
    <#
    .SYNOPSIS
        Issues one Microsoft Graph request, retrying only on HTTP 429 or 503.
    .DESCRIPTION
        Calls Invoke-MgGraphRequest once. A response with HTTP 429 (throttled) or 503 (service
        unavailable) is retried up to MaxRetries times, honouring the Retry-After value when
        the thrown error carries one, otherwise the exponential backoff with jitter of
        Get-CaPackRetryDelay, the same pattern Invoke-CaPackGraphGet uses. Every other error,
        including a transient network failure such as a connection reset or a timeout, is
        re-thrown immediately and never retried here: unlike a GET, a POST that fails with a
        network error may already have reached the server and created something, so retrying
        it could create a duplicate; applying the same 429/503-only rule to every caller of
        this helper keeps that behaviour consistent instead of making it a special case for
        just one of them.
    .PARAMETER Method
        The HTTP method, for example GET or POST.
    .PARAMETER Uri
        The Graph request URI, either a full https URL or a path such as
        /identity/conditionalAccess/policies.
    .PARAMETER Body
        The request body for a method such as POST. Omit for a GET.
    .PARAMETER Headers
        Extra request headers, for example ConsistencyLevel for an advanced query.
    .PARAMETER MaxRetries
        Maximum retry attempts, default 4.
    .PARAMETER MaxSeconds
        Upper bound in seconds on any single retry delay, whether taken from a Retry-After
        header or computed by Get-CaPackRetryDelay, default 120.
    .OUTPUTS
        System.Object. Whatever Invoke-MgGraphRequest returns.
    .NOTES
        Internal helper, private to this file; not one of the seven functions a caller mocks.
        Requires an existing Microsoft Graph session (Connect-MgGraph), made by the caller.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter()]$Body,
        [Parameter()][hashtable]$Headers,
        [Parameter()][ValidateRange(0, 10)][int]$MaxRetries = 4,
        [Parameter()][double]$MaxSeconds = 120
    )
    $attempt = 0
    while ($true) {
        try {
            $arguments = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
            if ($PSBoundParameters.ContainsKey('Body')) { $arguments['Body'] = $Body }
            if ($PSBoundParameters.ContainsKey('Headers')) { $arguments['Headers'] = $Headers }
            return Invoke-MgGraphRequest @arguments
        }
        catch {
            $statusCode = 0
            if ($_.Exception.PSObject.Properties['StatusCode'] -and $_.Exception.StatusCode) {
                $statusCode = [int]$_.Exception.StatusCode
            }
            elseif ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response -and
                $_.Exception.Response.PSObject.Properties['StatusCode']) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            elseif ($_.Exception.Message -match '\b(429|503)\b') {
                $statusCode = [int]$Matches[1]
            }

            $isThrottled = ($statusCode -eq 429 -or $statusCode -eq 503)

            if ($isThrottled -and $attempt -lt $MaxRetries) {
                $attempt++
                $retryAfterSeconds = 0
                try {
                    $retryAfter = $null
                    if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response -and
                        $_.Exception.Response.PSObject.Properties['Headers'] -and $_.Exception.Response.Headers -and
                        $_.Exception.Response.Headers.PSObject.Properties['RetryAfter']) {
                        $retryAfter = $_.Exception.Response.Headers.RetryAfter
                    }
                    if ($retryAfter) {
                        if ($retryAfter.Delta) {
                            $retryAfterSeconds = $retryAfter.Delta.TotalSeconds
                        }
                        elseif ($retryAfter.Date) {
                            $retryAfterSeconds = ($retryAfter.Date - [System.DateTimeOffset]::UtcNow).TotalSeconds
                        }
                    }
                }
                catch {
                    $retryAfterSeconds = 0
                }
                if ($retryAfterSeconds -lt 0) { $retryAfterSeconds = 0 }
                $delay = if ($retryAfterSeconds -gt 0) { [math]::Min($retryAfterSeconds, $MaxSeconds) } else { Get-CaPackRetryDelay -Attempt $attempt -MaxSeconds $MaxSeconds }
                Write-Warning "Graph returned $statusCode for '$Uri'; retry $attempt of $MaxRetries in $([math]::Round($delay, 1)) seconds."
                Start-Sleep -Milliseconds ([int]($delay * 1000))
                continue
            }

            throw
        }
    }
}

function Disconnect-CaPackGraph {
    <#
    .SYNOPSIS
        Disconnects the current Microsoft Graph session.
    .DESCRIPTION
        Wraps Disconnect-MgGraph. The caller is responsible for calling this only when its own
        call to Connect-CaPackGraph returned true, so a session the caller reused rather than
        created is never torn down out from under whatever opened it.
    .OUTPUTS
        None.
    .EXAMPLE
        Disconnect-CaPackGraph
    #>
    [CmdletBinding()]
    param()
    $null = Disconnect-MgGraph
}

function Get-CaPackPolicies {
    <#
    .SYNOPSIS
        Lists every Conditional Access policy in the tenant.
    .DESCRIPTION
        Calls Invoke-CaPackGraphGet against /identity/conditionalAccess/policies, which follows
        paging and retries throttling and transient network failures.
    .OUTPUTS
        System.Object[]. Every policy, each with at least id and displayName.
    .EXAMPLE
        Get-CaPackPolicies
    .NOTES
        Requires an existing Microsoft Graph session with Policy.Read.All.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    , (Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/policies')
}

function New-CaPackPolicy {
    <#
    .SYNOPSIS
        Creates one Conditional Access policy.
    .DESCRIPTION
        Posts Policy to /identity/conditionalAccess/policies and returns the created policy,
        which includes its new id.
    .PARAMETER Policy
        The policy body, already fully substituted and with state forced to
        enabledForReportingButNotEnforced by the caller.
    .OUTPUTS
        System.Object. The created policy.
    .EXAMPLE
        New-CaPackPolicy -Policy $policyObject
    .NOTES
        Requires an existing Microsoft Graph session with Policy.ReadWrite.ConditionalAccess.
        Throws on failure; the caller decides whether that is fatal for the whole run. Retries
        only on HTTP 429 or 503 (see Invoke-CaPackGraphRetryable); any other failure, including
        a transient network error, is not retried, because this request may already have
        created the policy before the client saw the failure.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]$Policy
    )
    Invoke-CaPackGraphRetryable -Method POST -Uri '/identity/conditionalAccess/policies' -Body $Policy
}

function Get-CaPackGroup {
    <#
    .SYNOPSIS
        Reads one group's id, display name, and security-enabled flag.
    .DESCRIPTION
        Calls GET /groups/{id} with $select=id,displayName,securityEnabled. Returns $null when
        Graph responds 404, so a caller can treat "not found" as a plain value instead of a
        thrown error; any other failure is re-thrown unchanged.
    .PARAMETER GroupId
        The group's object id.
    .OUTPUTS
        System.Object. $null when the group does not exist.
    .EXAMPLE
        Get-CaPackGroup -GroupId '11111111-1111-1111-1111-111111111111'
    .NOTES
        Requires an existing Microsoft Graph session with GroupMember.Read.All (or broader).
        Retries only on HTTP 429 or 503 (see Invoke-CaPackGraphRetryable); a 404 still returns
        $null and no other error is retried.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$GroupId
    )
    try {
        Invoke-CaPackGraphRetryable -Method GET -Uri "/groups/$GroupId`?`$select=id,displayName,securityEnabled"
    }
    catch {
        if (Test-CaPackHttpNotFound -Exception $_.Exception) { return $null }
        throw
    }
}

function Get-CaPackGroupMemberCount {
    <#
    .SYNOPSIS
        Returns the number of members in a group without paging through them.
    .DESCRIPTION
        Calls GET /groups/{id}/members/$count with the ConsistencyLevel: eventual header that
        advanced Graph queries require, and returns the result as an integer.
    .PARAMETER GroupId
        The group's object id.
    .OUTPUTS
        System.Int32
    .EXAMPLE
        Get-CaPackGroupMemberCount -GroupId '11111111-1111-1111-1111-111111111111'
    .NOTES
        Requires an existing Microsoft Graph session with GroupMember.Read.All (or broader).
        Retries only on HTTP 429 or 503 (see Invoke-CaPackGraphRetryable).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$GroupId
    )
    $response = Invoke-CaPackGraphRetryable -Method GET -Uri "/groups/$GroupId/members/`$count" -Headers @{ ConsistencyLevel = 'eventual' }
    [int]$response
}

function Get-CaPackNamedLocation {
    <#
    .SYNOPSIS
        Reads one Conditional Access named location.
    .DESCRIPTION
        Calls GET /identity/conditionalAccess/namedLocations/{id}. Returns $null when Graph
        responds 404, so a caller can treat "not found" as a plain value instead of a thrown
        error; any other failure is re-thrown unchanged.
    .PARAMETER NamedLocationId
        The named location's object id.
    .OUTPUTS
        System.Object. $null when the named location does not exist.
    .EXAMPLE
        Get-CaPackNamedLocation -NamedLocationId '22222222-2222-2222-2222-222222222222'
    .NOTES
        Requires an existing Microsoft Graph session with Policy.Read.All. Retries only on HTTP
        429 or 503 (see Invoke-CaPackGraphRetryable); a 404 still returns $null and no other
        error is retried.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$NamedLocationId
    )
    try {
        Invoke-CaPackGraphRetryable -Method GET -Uri "/identity/conditionalAccess/namedLocations/$NamedLocationId"
    }
    catch {
        if (Test-CaPackHttpNotFound -Exception $_.Exception) { return $null }
        throw
    }
}
