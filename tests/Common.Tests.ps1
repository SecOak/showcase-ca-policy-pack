BeforeAll {
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        # Microsoft.Graph.Authentication is not installed on this machine. Define a stub with
        # the same name so Mock has a command to attach to; Invoke-CaPackGraphGet never calls
        # the real module, only this name, so the stub itself is never exercised.
        function Invoke-MgGraphRequest {
            [CmdletBinding()]
            param(
                [Parameter()][string]$Method,
                [Parameter()][string]$Uri,
                [Parameter()][string]$OutputType
            )
            throw "Invoke-MgGraphRequest stub was called directly with Method='$Method' Uri='$Uri' OutputType='$OutputType'; it should always be mocked in tests."
        }
    }
    . (Join-Path $PSScriptRoot '..' 'src' 'CaPack.Common.ps1')
}

Describe 'ConvertTo-CaPackNormalizedItem' {
    It 'removes volatile dotted paths and keeps everything else' {
        $item = [pscustomobject]@{
            id     = 'p1'
            policy = [pscustomobject]@{ id = 'pol'; lastModifiedDateTime = '2026-09-30T10:00:00Z'; lastModifiedBy = [pscustomobject]@{ user = 'x' }; displayName = 'Policy' }
        }
        $normalized = ConvertTo-CaPackNormalizedItem -Item $item -VolatileFields 'policy.lastModifiedDateTime', 'policy.lastModifiedBy'
        $normalized.policy.Keys | Should -Be @('displayName', 'id')
        $normalized.id | Should -Be 'p1'
    }

    It 'removes @odata properties at every depth, including inside arrays' {
        $item = @{
            '@odata.context' = 'ctx'; id = '1'
            nested           = @{ '@odata.type' = '#t'; value = 1 }
            rules            = @(@{ '@odata.type' = '#r'; id = 'r1' })
        }
        $normalized = ConvertTo-CaPackNormalizedItem -Item $item -VolatileFields @()
        $normalized.Keys | Should -Be @('id', 'nested', 'rules')
        $normalized.nested.Keys | Should -Be @('value')
        $normalized.rules[0].Keys | Should -Be @('id')
    }

    It 'sorts keys in ordinal order and returns an ordered hashtable' {
        $normalized = ConvertTo-CaPackNormalizedItem -Item ([pscustomobject]@{ b = 1; Z = 2; a = 3 }) -VolatileFields @()
        $normalized | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
        $normalized.Keys | Should -Be @('Z', 'a', 'b')
    }

    It 'applies a volatile path to every element of an array' {
        $item = @{ id = '1'; rules = @(@{ id = 'a'; stamp = 1 }, @{ id = 'b'; stamp = 2 }) }
        $normalized = ConvertTo-CaPackNormalizedItem -Item $item -VolatileFields 'rules.stamp'
        $normalized.rules.Count | Should -Be 2
        $normalized.rules[1].Keys | Should -Be @('id')
    }

    It 'keeps array order, nulls, and empty arrays, and is order-stable across key order' {
        $first = [pscustomobject]@{ id = '1'; modifiedDateTime = '2026-01-01T00:00:00Z'; state = 'enabled'; conditions = [pscustomobject]@{ users = [pscustomobject]@{ excludeUsers = @('u1') } } }
        $second = [pscustomobject]@{ conditions = [pscustomobject]@{ users = [pscustomobject]@{ excludeUsers = @('u1') } }; state = 'enabled'; modifiedDateTime = '2026-09-30T00:00:00Z'; id = '1' }
        $a = ConvertTo-Json -InputObject (ConvertTo-CaPackNormalizedItem -Item $first -VolatileFields 'modifiedDateTime') -Depth 10 -Compress
        $b = ConvertTo-Json -InputObject (ConvertTo-CaPackNormalizedItem -Item $second -VolatileFields 'modifiedDateTime') -Depth 10 -Compress
        $a | Should -Be $b
    }

    It 'treats a null item as an empty object' {
        (ConvertTo-CaPackNormalizedItem -Item $null -VolatileFields @()).Count | Should -Be 0
    }

    It 'unwraps a pipeline-wrapped array instead of treating it as an object' {
        $normalized = ConvertTo-CaPackNormalizedItem -Item ([ordered]@{ id = '1'; list = (Write-Output -NoEnumerate -InputObject @('a', 'b')) }) -VolatileFields @()
        (ConvertTo-Json -InputObject $normalized -Depth 10 -Compress) | Should -Be '{"id":"1","list":["a","b"]}'
    }
}

Describe 'Compare-CaPackValue' {
    It 'reports a changed scalar field with its path, expected, and actual value' {
        $changes = [System.Collections.Generic.List[object]]::new()
        Compare-CaPackValue -Path '' -Before @{ state = 'disabled' } -After @{ state = 'enabled' } -Changes $changes
        $changes.Count | Should -Be 1
        $changes[0].Path | Should -Be 'state'
        $changes[0].Before | Should -Be 'disabled'
        $changes[0].After | Should -Be 'enabled'
    }

    It 'reports nested object fields with a dotted path' {
        $changes = [System.Collections.Generic.List[object]]::new()
        $before = @{ conditions = @{ users = @{ includeUsers = @('All') } } }
        $after = @{ conditions = @{ users = @{ includeUsers = @('None') } } }
        Compare-CaPackValue -Path '' -Before $before -After $after -Changes $changes
        $changes.Count | Should -Be 1
        $changes[0].Path | Should -Be 'conditions.users.includeUsers'
        $changes[0].SetDelta | Should -BeTrue
        $changes[0].Before | Should -Be @('All')
        $changes[0].After | Should -Be @('None')
    }

    It 'matches array elements by id and recurses, reporting the id in the path' {
        $changes = [System.Collections.Generic.List[object]]::new()
        $before = @(@{ id = 'a'; value = 1 })
        $after = @(@{ id = 'a'; value = 2 })
        Compare-CaPackValue -Path 'rules' -Before $before -After $after -Changes $changes
        $changes.Count | Should -Be 1
        $changes[0].Path | Should -Be 'rules[id=a].value'
    }

    It 'treats null and an empty array as equal, and reports nothing' {
        $changes = [System.Collections.Generic.List[object]]::new()
        Compare-CaPackValue -Path 'excludeUsers' -Before $null -After @() -Changes $changes
        $changes.Count | Should -Be 0
    }

    It 'recurses into a missing object as if it were empty, reporting each nested field' {
        $changes = [System.Collections.Generic.List[object]]::new()
        Compare-CaPackValue -Path 'conditions' -Before $null -After @{ users = @{ includeUsers = @('All') } } -Changes $changes
        $changes.Count | Should -Be 1
        $changes[0].Path | Should -Be 'conditions.users.includeUsers'
    }

    It 'does not throw when an array mixes objects and a null element' {
        $changes = [System.Collections.Generic.List[object]]::new()
        $before = @(@{ id = 'a' }, $null)
        $after = @(@{ id = 'a' })
        # The ids-usable check must stop treating this as id-matchable the moment it sees the
        # null (it is not a dictionary and has no 'id'), falling back to positional comparison
        # instead of indexing 'id' on $null, which throws under StrictMode.
        { Compare-CaPackValue -Path 'list' -Before $before -After $after -Changes $changes } | Should -Not -Throw
        $changes.Count | Should -Be 1
        $changes[0].Path | Should -Be 'list[1]'
    }
}

Describe 'Get-CaPackRetryDelay' {
    It 'grows with the attempt number' {
        $first = Get-CaPackRetryDelay -Attempt 1
        $second = Get-CaPackRetryDelay -Attempt 2
        $third = Get-CaPackRetryDelay -Attempt 3
        # Each attempt's exponential floor (2^n) already clears the next jitter's ceiling
        # (1 second), so the comparison holds regardless of the random jitter drawn.
        $first | Should -BeLessThan $second
        $second | Should -BeLessThan $third
    }

    It 'caps the delay so a large attempt number does not grow unbounded' {
        $delay = Get-CaPackRetryDelay -Attempt 20 -MaxSeconds 120
        $delay | Should -BeLessOrEqual 121
        $delay | Should -BeGreaterThan 119
    }
}

Describe 'Test-CaPackTransientNetworkError' {
    It 'treats a network request exception as transient' {
        Test-CaPackTransientNetworkError -Exception ([System.Net.Http.HttpRequestException]::new('reset')) | Should -BeTrue
    }

    It 'treats a timeout as transient' {
        Test-CaPackTransientNetworkError -Exception ([System.Threading.Tasks.TaskCanceledException]::new('timeout')) | Should -BeTrue
    }

    It 'treats a wrapped transient exception as transient' {
        $inner = [System.Net.Http.HttpRequestException]::new('reset')
        $outer = [System.Exception]::new('outer', $inner)
        Test-CaPackTransientNetworkError -Exception $outer | Should -BeTrue
    }

    It 'treats an unrelated exception as not transient' {
        Test-CaPackTransientNetworkError -Exception ([System.InvalidOperationException]::new('nope')) | Should -BeFalse
    }

    It 'treats a null exception as not transient' {
        Test-CaPackTransientNetworkError -Exception $null | Should -BeFalse
    }

    It 'treats an HttpRequestException carrying a StatusCode as not transient' {
        # Microsoft.Graph.PowerShell.Authentication.Helpers.HttpResponseException also derives
        # from HttpRequestException and carries a StatusCode; simulated here with the built-in
        # type's own StatusCode constructor, since checking only for the concrete
        # Microsoft.PowerShell.Commands.HttpResponseException type would miss it and treat a
        # real Graph 404 or 403 as a retryable network failure.
        $ex = [System.Net.Http.HttpRequestException]::new('Not Found', $null, [System.Net.HttpStatusCode]::NotFound)
        Test-CaPackTransientNetworkError -Exception $ex | Should -BeFalse
    }

    It 'treats an exception carrying a Response as not transient' {
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
        $ex = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', $response)
        Test-CaPackTransientNetworkError -Exception $ex | Should -BeFalse
    }
}

Describe 'ConvertTo-CaPackStableJson' {
    It 'produces byte-for-byte identical text for two differently ordered inputs' {
        $first = @{ name = 'x'; items = @(@{ id = 2; k = 'a' }, @{ id = 1; k = 'b' }) }
        $second = [pscustomobject]@{ items = @([pscustomobject]@{ k = 'a'; id = 2 }, [pscustomobject]@{ k = 'b'; id = 1 }); name = 'x' }
        $a = ConvertTo-CaPackStableJson -InputObject $first
        $b = ConvertTo-CaPackStableJson -InputObject $second
        $a | Should -Be $b
        [System.Text.Encoding]::UTF8.GetBytes($a) | Should -Be ([System.Text.Encoding]::UTF8.GetBytes($b))
    }

    It 'keeps array order while sorting object keys' {
        ConvertTo-CaPackStableJson -InputObject @{ list = @(3, 1, 2); b = 1; a = 2 } | Should -Be '{"a":2,"b":1,"list":[3,1,2]}'
    }

    It 'keeps single-element arrays, empty arrays, and null as they are' {
        ConvertTo-CaPackStableJson -InputObject @{ one = @('a'); none = @(); nothing = $null } |
            Should -Be '{"none":[],"nothing":null,"one":["a"]}'
    }
}

Describe 'Invoke-CaPackGraphGet' {
    BeforeEach {
        Mock Start-Sleep { }
    }

    It 'follows @odata.nextLink across two pages and retries once on a mocked 429' {
        $script:callCount = 0
        Mock Invoke-MgGraphRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                throw [System.Net.Http.HttpRequestException]::new('Too many requests', $null, [System.Net.HttpStatusCode]::TooManyRequests)
            }
            if ($script:callCount -eq 2) {
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = '1' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/page2' }
            }
            return [pscustomobject]@{ value = @([pscustomobject]@{ id = '2' }) }
        }

        $items = Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/policies' -MaxRetries 3

        $items.Count | Should -Be 2
        $items[0].id | Should -Be '1'
        $items[1].id | Should -Be '2'
        Should -Invoke Invoke-MgGraphRequest -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'throws a plain error once the retries for a page are exhausted' {
        Mock Invoke-MgGraphRequest {
            throw [System.Net.Http.HttpRequestException]::new('Too many requests', $null, [System.Net.HttpStatusCode]::TooManyRequests)
        }

        { Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/policies' -MaxRetries 1 } | Should -Throw '*failed after 1 retry*'
        Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
    }

    It 'returns a single resource as a one-element array when the response has no value property' {
        Mock Invoke-MgGraphRequest { return [pscustomobject]@{ displayName = 'policy A' } }

        $items = Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/policies/p1'

        $items.Count | Should -Be 1
        $items[0].displayName | Should -Be 'policy A'
    }

    It 'waits the Retry-After header value from a mocked 429 response, not the computed backoff' {
        $script:callCount = 0
        Mock Invoke-MgGraphRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
                $response.Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([TimeSpan]::FromSeconds(5))
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Too many requests', $response)
            }
            return [pscustomobject]@{ value = @([pscustomobject]@{ id = '1' }) }
        }

        $items = Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/policies' -MaxRetries 1

        $items.Count | Should -Be 1
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 5000 }
    }

    It 'caps a Retry-After header larger than the backoff MaxSeconds' {
        Mock Invoke-MgGraphRequest {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
            $response.Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([TimeSpan]::FromSeconds(600))
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Too many requests', $response)
        }

        { Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/policies' -MaxRetries 1 } | Should -Throw '*failed after 1 retry*'
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 120000 }
    }

    It 'retries a transient network error on the computed backoff' {
        $script:callCount = 0
        Mock Invoke-MgGraphRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                throw [System.Net.Http.HttpRequestException]::new('Connection reset')
            }
            return [pscustomobject]@{ value = @([pscustomobject]@{ id = '1' }) }
        }

        $items = Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/policies' -MaxRetries 1

        $items.Count | Should -Be 1
        Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'does not retry a mocked 404 and surfaces it unchanged with its original exception type' {
        Mock Invoke-MgGraphRequest {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', $response)
        }

        $errorRecord = $null
        try {
            Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/policies' -MaxRetries 3
        }
        catch {
            $errorRecord = $_
        }

        # A 404 has a StatusCode and a Response, so Test-CaPackTransientNetworkError must say
        # "not transient" even though HttpResponseException also derives from
        # HttpRequestException; it must then surface unchanged rather than being retried or
        # wrapped in a new error.
        $errorRecord | Should -Not -BeNullOrEmpty
        $errorRecord.Exception | Should -BeOfType [Microsoft.PowerShell.Commands.HttpResponseException]
        $errorRecord.Exception.Response.StatusCode | Should -Be ([System.Net.HttpStatusCode]::NotFound)
        Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'preserves the original exception as InnerException once retries for a 429 are exhausted' {
        Mock Invoke-MgGraphRequest {
            throw [System.Net.Http.HttpRequestException]::new('Too many requests', $null, [System.Net.HttpStatusCode]::TooManyRequests)
        }

        $errorRecord = $null
        try {
            Invoke-CaPackGraphGet -Uri '/identity/conditionalAccess/policies' -MaxRetries 1
        }
        catch {
            $errorRecord = $_
        }

        $errorRecord.Exception.Message | Should -BeLike '*failed after 1 retry*'
        $errorRecord.Exception.InnerException | Should -BeOfType [System.Net.Http.HttpRequestException]
        $errorRecord.Exception.InnerException.Message | Should -Be 'Too many requests'
    }
}

Describe 'Test-CaPackPlaceholder' {
    It 'returns each distinct token name once, in first-seen order' {
        $json = '{"a":"{{ONE}}","b":"{{TWO}}-{{ONE}}"}'
        # Captured to a variable before piping: the function returns its array with the
        # unary comma operator so a single or empty result is never unwrapped, which means
        # piping the call's result directly into Should sends one pipeline object (the whole
        # array) instead of each element, and Should -Be then compares a nested array
        # against a flat one. Assigning first lets the normal array-to-pipeline unroll
        # happen, so Should -Be compares the elements as intended.
        $tokens = Test-CaPackPlaceholder -Json $json
        $tokens | Should -Be @('ONE', 'TWO')
    }

    It 'returns an empty array when there are no tokens' {
        (Test-CaPackPlaceholder -Json '{"a":"b"}').Count | Should -Be 0
    }
}

Describe 'Expand-CaPackPlaceholder' {
    It 'replaces every token with its value' {
        $json = '{"a":"{{ONE}}","b":"{{TWO}}"}'
        Expand-CaPackPlaceholder -Json $json -Values @{ ONE = 'x'; TWO = 'y' } | Should -Be '{"a":"x","b":"y"}'
    }

    It 'replaces a repeated token everywhere it appears' {
        $json = '{"a":"{{ONE}}","b":"{{ONE}}"}'
        Expand-CaPackPlaceholder -Json $json -Values @{ ONE = 'x' } | Should -Be '{"a":"x","b":"x"}'
    }

    It 'throws listing every unresolved token name' {
        $json = '{"a":"{{ONE}}","b":"{{TWO}}"}'
        { Expand-CaPackPlaceholder -Json $json -Values @{ ONE = 'x' } } | Should -Throw '*TWO*'
    }

    It 'returns the text unchanged when it has no tokens' {
        Expand-CaPackPlaceholder -Json '{"a":"b"}' -Values @{} | Should -Be '{"a":"b"}'
    }
}
