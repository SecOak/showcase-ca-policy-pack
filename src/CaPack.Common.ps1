#Requires -Version 7.0
<#
    CaPack.Common.ps1

    Shared helper functions, dot-sourced by the conditional access policy pack scripts
    (Import-CaPolicyPack.ps1, Export-CaBaseline.ps1, Compare-CaBaseline.ps1). This file does
    not import or connect to Microsoft Graph itself; the scripts that dot-source it own the
    Microsoft.Graph.Authentication import and the Connect-MgGraph call.

    Provenance. The functions below were adapted, with the SecOakDrift / SecOak prefix
    renamed to CaPack, from securityoak-drift at commit 61b8267. Nothing else from that
    repository was copied; no git history, fixtures, findings, tenant context, EndpointLog,
    or token handling came with them.

        src\Diff\Normalize.ps1
            ConvertTo-SecOakDriftNormalizedValue  -> ConvertTo-CaPackNormalizedValue
            ConvertTo-SecOakDriftNormalizedItem   -> ConvertTo-CaPackNormalizedItem

        src\Diff\Compare.ps1
            Get-SecOakDriftMember           -> Get-CaPackMember
            ConvertTo-SecOakDriftScalarText -> ConvertTo-CaPackScalarText
            Add-SecOakDriftFieldChange      -> Add-CaPackFieldChange
            Compare-SecOakDriftValue        -> Compare-CaPackValue

        src\Core\Helpers.ps1
            Get-SecOakRetryDelay             -> Get-CaPackRetryDelay (exponential backoff is
                                                 now capped before jitter is added; see the
                                                 function help)
            Test-SecOakTransientNetworkError -> Test-CaPackTransientNetworkError
            ConvertTo-SecOakStableValue       -> ConvertTo-CaPackStableValue (internal helper)
            ConvertTo-SecOakStableJson        -> ConvertTo-CaPackStableJson

        src\Core\Graph.ps1
            The paging loop and the 429 / 503 / Retry-After retry logic of
            Invoke-SecOakGraphGetAttempt and Invoke-SecOakHttpGet were rewritten as
            Invoke-CaPackGraphGet, calling Invoke-MgGraphRequest instead of a hand-rolled
            bearer token request. Tenant context, EndpointLog, and token acquisition were
            removed; this product authenticates with Connect-MgGraph in the scripts.

    Expand-CaPackPlaceholder and Test-CaPackPlaceholder are new for this product. Nothing in
    either of them is copied from securityoak-drift.
#>

Set-StrictMode -Version Latest

function ConvertTo-CaPackNormalizedValue {
    <#
    .SYNOPSIS
        Recursively rebuilds a value for comparison.
    .DESCRIPTION
        Objects become ordered hashtables with keys in ordinal order. Properties whose name
        starts with @odata. are dropped at every depth, as are properties whose dotted path
        is listed in VolatileFields. Dates become UTC text, so a date parsed by
        ConvertFrom-Json equals the same date read from Graph as text. Arrays keep their
        order.
    .PARAMETER Value
        The value to rebuild.
    .PARAMETER Path
        Dotted path of the value, empty at the root. Array elements share the path of the
        array.
    .PARAMETER VolatileFields
        Dotted paths to drop.
    .OUTPUTS
        System.Object
    .NOTES
        Internal helper. No permissions required.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Value,
        [Parameter()][string]$Path = '',
        [Parameter()][string[]]$VolatileFields = @()
    )
    if ($null -eq $Value) { return $null }
    if ($Value -is [psobject] -and $Value.PSObject.BaseObject -isnot [System.Management.Automation.PSCustomObject]) { $Value = $Value.PSObject.BaseObject }
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }

    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $byName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        if ($Value -is [System.Collections.IDictionary]) { foreach ($key in $Value.Keys) { $byName["$key"] = $Value[$key] } }
        else { foreach ($property in $Value.PSObject.Properties) { $byName[$property.Name] = $property.Value } }
        $names = [string[]]@($byName.Keys)
        [array]::Sort($names, [System.StringComparer]::Ordinal)
        $result = [ordered]@{}
        foreach ($name in $names) {
            if ($name.StartsWith('@odata.', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $childPath = if ($Path) { "$Path.$name" } else { $name }
            if ($VolatileFields -contains $childPath) { continue }
            $result[$name] = ConvertTo-CaPackNormalizedValue -Value $byName[$name] -Path $childPath -VolatileFields $VolatileFields
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($element in $Value) { $list.Add((ConvertTo-CaPackNormalizedValue -Value $element -Path $Path -VolatileFields $VolatileFields)) }
        return , $list.ToArray()
    }
    $Value
}

function ConvertTo-CaPackNormalizedItem {
    <#
    .SYNOPSIS
        Normalises one collected item for comparison.
    .DESCRIPTION
        Removes volatile fields and every @odata.* property, sorts keys, and returns a plain
        ordered hashtable. Two items that differ only in volatile fields or key order
        normalise to the same data.
    .PARAMETER Item
        The collected item, a hashtable or a custom object.
    .PARAMETER VolatileFields
        Dotted paths to remove, for example policy.lastModifiedDateTime.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    .NOTES
        Internal helper. No permissions required.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Item,
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$VolatileFields = @()
    )
    if ($null -eq $Item) { return [ordered]@{} }
    $normalized = ConvertTo-CaPackNormalizedValue -Value $Item -Path '' -VolatileFields @($VolatileFields)
    if ($normalized -isnot [System.Collections.IDictionary]) { throw 'A collected item must be an object, not a single value or a list.' }
    $normalized
}

function Get-CaPackMember {
    <#
    .SYNOPSIS
        Reads a named member from a hashtable or a custom object, or returns $null when
        absent.
    .PARAMETER InputObject
        The hashtable or custom object to read from.
    .PARAMETER Name
        The member name.
    .OUTPUTS
        System.Object
    .NOTES
        Internal helper. A normalised item is a hashtable; an item loaded straight from JSON
        is a custom object. This works with either.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    $null
}

function ConvertTo-CaPackScalarText {
    <#
    .SYNOPSIS
        Formats a scalar the same way on both sides of a comparison.
    .PARAMETER Value
        The scalar value to format.
    .OUTPUTS
        System.String
    .NOTES
        Internal helper. Culture-invariant, so the result never depends on the machine
        language.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
}

function Add-CaPackFieldChange {
    <#
    .SYNOPSIS
        Appends one field change to a list.
    .DESCRIPTION
        SetDelta is true when the change comes from comparing two arrays of scalars as sets:
        Before then holds only the removed values and After only the added values.
    .PARAMETER List
        The list to append to.
    .PARAMETER Path
        Dotted path of the field that changed.
    .PARAMETER Before
        The value on the earlier side.
    .PARAMETER After
        The value on the later side.
    .PARAMETER SetDelta
        Marks the change as a set difference rather than a plain before/after pair.
    .NOTES
        Internal helper.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][AllowNull()]$Before,
        [Parameter()][AllowNull()]$After,
        [Parameter()][switch]$SetDelta
    )
    $List.Add([pscustomobject][ordered]@{ Path = $Path; Before = $Before; After = $After; SetDelta = [bool]$SetDelta })
}

function Compare-CaPackValue {
    <#
    .SYNOPSIS
        Compares two normalised values and appends field changes for every difference.
    .DESCRIPTION
        Scalars compare by value (strings ordinal, case-sensitive). Arrays of scalars compare
        as sets and give one change whose Before lists removed values and whose After lists
        added values. Arrays of objects that all have an id are matched by id and recursed
        with the path prop[id=value]. Other arrays compare by position with the path
        prop[index]. Objects recurse with dotted paths. Null and missing are equal, and so are
        null and an empty array. An object on one side and null on the other recurses as if
        the null side were an empty object, so a missing conditions object still reports each
        nested field.
    .PARAMETER Path
        Dotted path of the value being compared, empty at the root.
    .PARAMETER Before
        The earlier value.
    .PARAMETER After
        The later value.
    .PARAMETER Changes
        The list that field changes are appended to.
    .NOTES
        Internal helper.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter()][AllowNull()]$Before,
        [Parameter()][AllowNull()]$After,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Changes
    )
    $beforeIsDictionary = $Before -is [System.Collections.IDictionary]
    $afterIsDictionary = $After -is [System.Collections.IDictionary]
    $beforeIsArray = $Before -is [array]
    $afterIsArray = $After -is [array]

    if (($beforeIsDictionary -and ($afterIsDictionary -or $null -eq $After)) -or ($afterIsDictionary -and $null -eq $Before)) {
        $left = if ($beforeIsDictionary) { $Before } else { @{} }
        $right = if ($afterIsDictionary) { $After } else { @{} }
        $keys = [System.Collections.Generic.List[string]]::new()
        foreach ($key in @($left.Keys) + @($right.Keys)) { if (-not $keys.Contains("$key")) { $keys.Add("$key") } }
        $keys.Sort([System.StringComparer]::Ordinal)
        foreach ($key in $keys) {
            $child = if ($Path) { "$Path.$key" } else { $key }
            Compare-CaPackValue -Path $child -Before $left[$key] -After $right[$key] -Changes $Changes
        }
        return
    }

    if (($beforeIsArray -and ($afterIsArray -or $null -eq $After)) -or ($afterIsArray -and $null -eq $Before)) {
        # Assigned inside each branch, not captured from the if-statement's result: a
        # single-element or empty array returned as the "value" of an if/else would
        # otherwise be unwrapped by PowerShell's pipeline enumeration, leaving $left or
        # $right as a scalar or $null instead of an array, which fails under StrictMode.
        if ($beforeIsArray) { $left = @($Before) } else { $left = @() }
        if ($afterIsArray) { $right = @($After) } else { $right = @() }
        if ($left.Count -eq 0 -and $right.Count -eq 0) { return }
        $everything = @($left) + @($right)
        # Counted rather than negated directly: when the only matching element is itself
        # $null, Where-Object's result is that lone $null (not a one-element array), and
        # "-not $null" is $true, which would wrongly report no match. Wrapping in @() and
        # checking Count avoids that collapse, so an array mixing objects and $null is
        # classified correctly instead of crashing later by being treated as all-objects.
        $allScalar = (@($everything | Where-Object { $_ -is [System.Collections.IDictionary] -or $_ -is [array] })).Count -eq 0
        $allObjects = (@($everything | Where-Object { $_ -isnot [System.Collections.IDictionary] })).Count -eq 0

        if ($allScalar) {
            $beforeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $afterSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($element in $left) { $null = $beforeSet.Add([string](ConvertTo-CaPackScalarText $element)) }
            foreach ($element in $right) { $null = $afterSet.Add([string](ConvertTo-CaPackScalarText $element)) }
            $removed = [string[]]@($beforeSet | Where-Object { -not $afterSet.Contains($_) })
            $added = [string[]]@($afterSet | Where-Object { -not $beforeSet.Contains($_) })
            [array]::Sort($removed, [System.StringComparer]::Ordinal)
            [array]::Sort($added, [System.StringComparer]::Ordinal)
            if ($removed.Count -gt 0 -or $added.Count -gt 0) {
                Add-CaPackFieldChange -List $Changes -Path $Path -Before $removed -After $added -SetDelta
            }
            return
        }

        $idsUsable = $false
        if ($allObjects) {
            $idsUsable = $true
            foreach ($side in $left, $right) {
                $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                foreach ($element in $side) {
                    $identifier = ConvertTo-CaPackScalarText $element['id']
                    if ([string]::IsNullOrEmpty($identifier) -or -not $seen.Add($identifier)) { $idsUsable = $false }
                }
            }
        }

        if ($idsUsable) {
            $leftById = @{}
            $rightById = @{}
            foreach ($element in $left) { $leftById[(ConvertTo-CaPackScalarText $element['id'])] = $element }
            foreach ($element in $right) { $rightById[(ConvertTo-CaPackScalarText $element['id'])] = $element }
            $ids = [string[]]@(@($leftById.Keys) + @($rightById.Keys) | Select-Object -Unique)
            [array]::Sort($ids, [System.StringComparer]::Ordinal)
            foreach ($identifier in $ids) {
                $child = "$Path[id=$identifier]"
                if ($leftById.ContainsKey($identifier) -and $rightById.ContainsKey($identifier)) {
                    Compare-CaPackValue -Path $child -Before $leftById[$identifier] -After $rightById[$identifier] -Changes $Changes
                }
                else {
                    Add-CaPackFieldChange -List $Changes -Path $child -Before $leftById[$identifier] -After $rightById[$identifier]
                }
            }
            return
        }

        $length = [math]::Max($left.Count, $right.Count)
        for ($index = 0; $index -lt $length; $index++) {
            $child = "$Path[$index]"
            if ($index -lt $left.Count -and $index -lt $right.Count) {
                Compare-CaPackValue -Path $child -Before $left[$index] -After $right[$index] -Changes $Changes
            }
            else {
                Add-CaPackFieldChange -List $Changes -Path $child -Before $(if ($index -lt $left.Count) { $left[$index] }) -After $(if ($index -lt $right.Count) { $right[$index] })
            }
        }
        return
    }

    if ($null -eq $Before -and $null -eq $After) { return }
    $structuredBefore = $beforeIsDictionary -or $beforeIsArray
    $structuredAfter = $afterIsDictionary -or $afterIsArray
    if ($structuredBefore -or $structuredAfter) {
        Add-CaPackFieldChange -List $Changes -Path $Path -Before $Before -After $After
        return
    }
    if ($Before -is [string] -and $After -is [string]) {
        if (-not [string]::Equals($Before, $After, [System.StringComparison]::Ordinal)) {
            Add-CaPackFieldChange -List $Changes -Path $Path -Before $Before -After $After
        }
        return
    }
    if ($null -eq $Before -or $null -eq $After -or -not [string]::Equals((ConvertTo-CaPackScalarText $Before), (ConvertTo-CaPackScalarText $After), [System.StringComparison]::Ordinal)) {
        Add-CaPackFieldChange -List $Changes -Path $Path -Before $Before -After $After
    }
}

function Test-CaPackTransientNetworkError {
    <#
    .SYNOPSIS
        Returns true when an exception, or any exception it wraps, is a network failure worth
        retrying.
    .DESCRIPTION
        HttpRequestException (connection reset, name resolution, TLS) and
        TaskCanceledException (the request timeout) are transient. Any exception that carries
        a non-null StatusCode or Response property is never treated as a network failure here,
        because it already represents a completed HTTP response (a 4xx, 5xx, or similar) rather
        than a failure to get one; Microsoft.PowerShell.Commands.HttpResponseException is one
        such type, but Invoke-MgGraphRequest throws its own
        Microsoft.Graph.PowerShell.Authentication.Helpers.HttpResponseException, which also
        derives from HttpRequestException and would otherwise be misclassified as transient,
        causing every non-throttling Graph error (400, 403, 404, and so on) to be retried.
        Checking the properties directly, rather than the concrete type, catches both.
    .PARAMETER Exception
        The exception to inspect.
    .OUTPUTS
        System.Boolean
    .NOTES
        Internal helper.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][System.Exception]$Exception
    )
    $current = $Exception
    while ($null -ne $current) {
        # PSObject.Properties lookups so a type without these properties is never probed
        # directly, which would throw under StrictMode instead of just being absent.
        $hasStatusCode = $current.PSObject.Properties['StatusCode'] -and $null -ne $current.StatusCode
        $hasResponse = $current.PSObject.Properties['Response'] -and $null -ne $current.Response
        if ($hasStatusCode -or $hasResponse) { return $false }
        if ($current -is [Microsoft.PowerShell.Commands.HttpResponseException]) { return $false }
        if ($current -is [System.Net.Http.HttpRequestException] -or $current -is [System.Threading.Tasks.TaskCanceledException]) { return $true }
        $current = $current.InnerException
    }
    $false
}

function Get-CaPackRetryDelay {
    <#
    .SYNOPSIS
        Returns the exponential backoff delay in seconds, with jitter, for a retry attempt.
    .DESCRIPTION
        The exponential part doubles with every attempt (2, 4, 8, 16 seconds, and so on) and
        is capped at MaxSeconds before a small amount of jitter (0 to 1 second) is added, so a
        caller can rely on the result never exceeding MaxSeconds by more than a second. The
        drift source this was adapted from left the exponential part uncapped; the cap was
        added here because this pack's callers run unattended and a cap keeps a long run of
        retries bounded.
    .PARAMETER Attempt
        The retry attempt number, starting at 1.
    .PARAMETER MaxSeconds
        Upper bound on the exponential part before jitter, default 120.
    .OUTPUTS
        System.Double
    .NOTES
        Internal helper.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter()][double]$MaxSeconds = 120
    )
    $exponential = [math]::Min([math]::Pow(2, $Attempt), $MaxSeconds)
    $exponential + (Get-Random -Minimum 0 -Maximum 1000) / 1000
}

function ConvertTo-CaPackStableValue {
    <#
    .SYNOPSIS
        Rebuilds a value so every object has its keys in ordinal order, recursively.
    .PARAMETER Value
        The value to rebuild.
    .OUTPUTS
        System.Object
    .NOTES
        Internal helper for ConvertTo-CaPackStableJson. Arrays keep their order.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    # A collection wrapped in a PSObject (for example by Write-Output -NoEnumerate) must be
    # treated as the collection, not as a property bag.
    if ($Value -is [psobject] -and $Value.PSObject.BaseObject -isnot [System.Management.Automation.PSCustomObject]) {
        $Value = $Value.PSObject.BaseObject
    }
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $pairs = if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) { [pscustomobject]@{ Key = "$key"; Value = $Value[$key] } }
        }
        else {
            foreach ($property in $Value.PSObject.Properties) { [pscustomobject]@{ Key = $property.Name; Value = $property.Value } }
        }
        $keys = [string[]]@($pairs | ForEach-Object { $_.Key })
        [array]::Sort($keys, [System.StringComparer]::Ordinal)
        $byKey = @{}
        foreach ($pair in $pairs) { $byKey[$pair.Key] = $pair.Value }
        $sorted = [ordered]@{}
        foreach ($key in $keys) { $sorted[$key] = ConvertTo-CaPackStableValue -Value $byKey[$key] }
        return $sorted
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($element in $Value) { $list.Add((ConvertTo-CaPackStableValue -Value $element)) }
        return , $list.ToArray()
    }
    $Value
}

function ConvertTo-CaPackStableJson {
    <#
    .SYNOPSIS
        Produces canonical compact JSON with object keys sorted recursively.
    .DESCRIPTION
        Two values that hold the same data produce the same text, whatever the key order of
        the objects they came from. Arrays keep their order. Used so two differently ordered
        inputs can be compared for equality byte for byte.
    .PARAMETER InputObject
        The value to serialise.
    .PARAMETER Depth
        Maximum depth, default 20.
    .OUTPUTS
        System.String
    .NOTES
        Internal helper. No permissions required.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter()][ValidateRange(1, 100)][int]$Depth = 20
    )
    $stable = ConvertTo-CaPackStableValue -Value $InputObject
    ConvertTo-Json -InputObject $stable -Depth $Depth -Compress
}

function Invoke-CaPackGraphGet {
    <#
    .SYNOPSIS
        Issues a Microsoft Graph GET, follows paging, and retries on throttling and transient
        network failures.
    .DESCRIPTION
        Calls Invoke-MgGraphRequest -Method GET -OutputType PSObject for Uri, then follows
        @odata.nextLink until it is absent, returning every item from the value property of
        every page as one array. A response with HTTP 429 (throttled) or 503 (service
        unavailable) is retried up to MaxRetries times per page, honouring the Retry-After
        value when the thrown error carries one, otherwise the exponential backoff with
        jitter of Get-CaPackRetryDelay. A transient network failure (see
        Test-CaPackTransientNetworkError, for example a connection reset or a request timeout)
        is retried the same way, always on the computed backoff since there is no HTTP
        response to carry a Retry-After value. When the retries for a page are exhausted, the
        last error is re-thrown as a plain error naming the Uri and the number of retries
        made.

        This is the only function in CaPack.Common.ps1 that calls Microsoft Graph, so a test
        can mock Invoke-MgGraphRequest and exercise every caller of Graph through it. It does
        not import Microsoft.Graph.Authentication and does not connect or disconnect; the
        calling script owns the session.
    .PARAMETER Uri
        The Graph request URI, either a full https URL or a path such as
        /identity/conditionalAccess/policies. Passed to Invoke-MgGraphRequest unchanged.
    .PARAMETER MaxRetries
        Maximum retry attempts per page, default 4.
    .PARAMETER MaxSeconds
        Upper bound in seconds on any single retry delay, whether taken from a Retry-After
        header or computed by Get-CaPackRetryDelay, default 120.
    .OUTPUTS
        System.Object[]. Every item from the value property of every page, in page order.
        When a response has no value property (a single resource rather than a collection),
        returns a one-element array holding that response.
    .EXAMPLE
        Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/policies'
    .NOTES
        Requires an existing Microsoft Graph session (Connect-MgGraph), made by the caller.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter()][ValidateRange(0, 10)][int]$MaxRetries = 4,
        [Parameter()][double]$MaxSeconds = 120
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $next = $Uri

    while ($next) {
        $attempt = 0
        $response = $null
        while ($true) {
            try {
                $response = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
                break
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
                $isTransient = Test-CaPackTransientNetworkError -Exception $_.Exception

                if (($isThrottled -or $isTransient) -and $attempt -lt $MaxRetries) {
                    $attempt++
                    $retryAfterSeconds = 0
                    if ($isThrottled) {
                        # Headers is HttpResponseHeaders, which has no string indexer; indexing
                        # it with ['Retry-After'] throws under strict mode instead of returning
                        # $null. Read the strongly typed RetryAfter value instead (a
                        # RetryConditionHeaderValue exposing either Delta or Date), wrapped so
                        # any failure to read it falls back to the computed backoff below.
                        try {
                            $retryAfter = $null
                            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response -and
                                $_.Exception.Response.PSObject.Properties['Headers'] -and $_.Exception.Response.Headers -and
                                $_.Exception.Response.Headers.PSObject.Properties['RetryAfter']) {
                                $retryAfter = $_.Exception.Response.Headers.RetryAfter
                            }
                            if ($retryAfter) {
                                # PowerShell already unwraps Delta/Date from Nullable<TimeSpan> /
                                # Nullable<DateTimeOffset> to the plain struct when read through
                                # property access, so there is no further .Value to read; doing
                                # so would throw PropertyNotFoundException under StrictMode and
                                # be swallowed by the catch below, silently losing the header.
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
                    }
                    $delay = if ($retryAfterSeconds -gt 0) { [math]::Min($retryAfterSeconds, $MaxSeconds) } else { Get-CaPackRetryDelay -Attempt $attempt -MaxSeconds $MaxSeconds }
                    $reason = if ($isThrottled) { "Graph returned $statusCode" } else { 'a transient network error occurred' }
                    Write-Warning "$reason for '$next'; retry $attempt of $MaxRetries in $([math]::Round($delay, 1)) seconds."
                    Start-Sleep -Milliseconds ([int]($delay * 1000))
                    continue
                }

                if ($isThrottled -or $isTransient) {
                    # Retries are exhausted. Wrap in a new exception rather than a bare string
                    # so the original exception (and its type, StatusCode, Response, and so on)
                    # survives as InnerException for a caller or log that inspects it.
                    $message = "Graph request to '$next' failed after $attempt retr$(if ($attempt -eq 1) { 'y' } else { 'ies' }): $($_.Exception.Message)"
                    throw [System.Exception]::new($message, $_.Exception)
                }

                # Not retryable at all (for example a 400, 403, or 404): rethrow the original
                # ErrorRecord unchanged, preserving its exception type and message instead of
                # replacing it with a new string-based error.
                $PSCmdlet.ThrowTerminatingError($_)
            }
        }

        if ($response -is [System.Collections.IDictionary]) {
            if ($response.Contains('value')) {
                foreach ($item in @($response['value'])) { $results.Add($item) }
                $next = if ($response.Contains('@odata.nextLink')) { $response['@odata.nextLink'] } else { $null }
            }
            else {
                $results.Add($response)
                $next = $null
            }
        }
        elseif ($response -and $response.PSObject.Properties['value']) {
            foreach ($item in @($response.value)) { $results.Add($item) }
            $next = if ($response.PSObject.Properties['@odata.nextLink']) { $response.'@odata.nextLink' } else { $null }
        }
        else {
            $results.Add($response)
            $next = $null
        }
    }

    , $results.ToArray()
}

function Test-CaPackPlaceholder {
    <#
    .SYNOPSIS
        Returns the distinct {{NAME}} placeholder tokens present in a block of JSON text.
    .DESCRIPTION
        A token is two opening braces, one or more uppercase letters, digits, or underscores,
        and two closing braces, for example {{BREAK_GLASS_GROUP_ID}}. Every template in this
        pack stays valid JSON with these tokens sitting inside string values, so this
        function and Expand-CaPackPlaceholder work on the raw text rather than on a parsed
        object.
    .PARAMETER Json
        The JSON text to scan.
    .OUTPUTS
        System.String[]. Each token name once, in the order it first appears. Empty when the
        text has no tokens.
    .NOTES
        New for this product; not adapted from securityoak-drift.
    .EXAMPLE
        Test-CaPackPlaceholder -Json (Get-Content .\templates\CA001-require-mfa.json -Raw)
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Json
    )
    $names = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($Json, '\{\{([A-Z0-9_]+)\}\}')) {
        $name = $match.Groups[1].Value
        if ($seen.Add($name)) { $names.Add($name) }
    }
    , $names.ToArray()
}

function Expand-CaPackPlaceholder {
    <#
    .SYNOPSIS
        Replaces every {{NAME}} token in a block of JSON text with its value.
    .DESCRIPTION
        Looks up each token found by Test-CaPackPlaceholder in Values by name and substitutes
        it as plain text. When one or more tokens have no entry in Values, throws once,
        listing every missing token name, so a caller preparing a template can report every
        gap in a single pass instead of one substitution at a time.
    .PARAMETER Json
        The JSON text containing {{NAME}} tokens.
    .PARAMETER Values
        A hashtable, or any other IDictionary, mapping each token name to its replacement
        text.
    .OUTPUTS
        System.String
    .NOTES
        New for this product; not adapted from securityoak-drift. Caller is responsible for
        making sure a substituted value cannot itself break the surrounding JSON, for example
        by passing a GUID or an already-escaped string.
    .EXAMPLE
        Expand-CaPackPlaceholder -Json $templateJson -Values @{ BREAK_GLASS_GROUP_ID = $groupId }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )
    $tokens = Test-CaPackPlaceholder -Json $Json
    $unresolved = [System.Collections.Generic.List[string]]::new()
    $result = $Json
    foreach ($token in $tokens) {
        if ($Values.Contains($token)) {
            $result = $result.Replace("{{$token}}", [string]$Values[$token])
        }
        else {
            $unresolved.Add($token)
        }
    }
    if ($unresolved.Count -gt 0) {
        throw "Unresolved placeholder token(s): $($unresolved -join ', ')"
    }
    $result
}
