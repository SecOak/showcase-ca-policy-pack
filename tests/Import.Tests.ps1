#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
<#
.SYNOPSIS
    Tests Import-CaPolicyPack.ps1 and CaPack.Graph.ps1 against the pack's own templates and
    manifest, with every Microsoft Graph call mocked.
.DESCRIPTION
    CaPack.Graph.ps1's seven functions (Connect-CaPackGraph, Disconnect-CaPackGraph,
    Get-CaPackPolicies, New-CaPackPolicy, Get-CaPackGroup, Get-CaPackGroupMemberCount,
    Get-CaPackNamedLocation) are dot-sourced once, for real, so Mock has real commands to
    attach to, then mocked per test. Import-CaPolicyPack.ps1 only re-sources CaPack.Graph.ps1
    when Connect-CaPackGraph is not already defined, so calling the script here never clobbers
    these mocks with the real functions.

    The 'Import-CaPolicyPack' Describe below mocks all seven of those functions and never
    touches Invoke-MgGraphRequest or Connect-MgGraph directly; two further Describe blocks
    (Connect-CaPackGraph session reuse, CaPack.Graph retry behavior) call the real
    Connect-CaPackGraph, New-CaPackPolicy, and Get-CaPackGroup functions, mocking only
    Get-MgContext, Connect-MgGraph, Disconnect-MgGraph, and Invoke-MgGraphRequest, to exercise
    the tenant-reuse and retry logic those wrappers add on top of the raw Graph calls.
.NOTES
    Author: Sec Oak
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:RepoRoot 'Import-CaPolicyPack.ps1'
    $script:TenantId = 'contoso.onmicrosoft.com'
    $script:BreakGlassGroupId = '11111111-1111-1111-1111-111111111111'
    $script:TrustedLocationId = '22222222-2222-2222-2222-222222222222'

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    . (Join-Path $script:RepoRoot 'src' 'CaPack.Graph.ps1')

    function New-CaPackFixturePack {
        <#
        Builds a minimal manifest plus one template file, pointed at the real schema, under a
        fresh directory. Returns the root path to pass as -TemplatePath.
        #>
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$TemplateJson,
            [Parameter()][string]$Id = 'CA901',
            [Parameter()][string]$DisplayName = 'CA901 Test template',
            [Parameter()][string]$RequiresSwitch
        )
        New-Item -ItemType Directory -Path (Join-Path $Root 'templates') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Root 'schema') -Force | Out-Null
        Copy-Item -Path (Join-Path $script:RepoRoot 'schema\conditionalAccessTemplate.schema.json') -Destination (Join-Path $Root 'schema\conditionalAccessTemplate.schema.json')
        Set-Content -Path (Join-Path $Root "templates\$Id.json") -Value $TemplateJson -NoNewline
        $manifestObject = [ordered]@{
            schemaVersion = '1.0'
            templates     = @(
                [ordered]@{
                    id             = $Id
                    file           = "templates/$Id.json"
                    displayName    = $DisplayName
                    licence        = 'Entra ID P1'
                    requiresSwitch = $RequiresSwitch
                    order          = 1
                    summary        = 'Test fixture.'
                }
            )
        }
        ($manifestObject | ConvertTo-Json -Depth 10) | Set-Content -Path (Join-Path $Root 'manifest.json')
        $Root
    }

    $script:ValidTemplateJson = '{"displayName":"CA901 Test template","state":"enabledForReportingButNotEnforced","conditions":{"applications":{"includeApplications":["All"]},"users":{"includeUsers":["All"],"excludeGroups":["{{BREAK_GLASS_GROUP_ID}}"]},"clientAppTypes":["all"]},"grantControls":{"operator":"OR","builtInControls":["mfa"]}}'

    # Not a realistic use of a named location (the shipped schema has no "locations" condition
    # to model one), but it exercises this script's own placeholder handling: the token sits in
    # a string array the schema already allows, alongside the break-glass placeholder.
    $script:LocationTemplateJson = '{"displayName":"CA901 Test template","state":"enabledForReportingButNotEnforced","conditions":{"applications":{"includeApplications":["All"]},"users":{"includeUsers":["All"],"excludeGroups":["{{BREAK_GLASS_GROUP_ID}}","{{TRUSTED_LOCATION_ID}}"]},"clientAppTypes":["all"]},"grantControls":{"operator":"OR","builtInControls":["mfa"]}}'
}

Describe 'Import-CaPolicyPack' {

    BeforeEach {
        # Backstop: if some path under test ever fell through to the real Graph plumbing
        # instead of the seven mocked wrapper functions below, these make that failure loud
        # and immediate instead of silently trying to reach a real tenant.
        Mock Invoke-MgGraphRequest { throw 'network reached' }
        Mock Connect-MgGraph { throw 'network reached' }

        Mock Connect-CaPackGraph { $true }
        Mock Disconnect-CaPackGraph { }
        Mock Get-CaPackGroup { [pscustomobject]@{ id = $GroupId; displayName = 'Break Glass'; securityEnabled = $true } }
        Mock Get-CaPackGroupMemberCount { 3 }
        Mock Get-CaPackNamedLocation { [pscustomobject]@{ id = $NamedLocationId; displayName = 'Trusted location' } }
        Mock Get-CaPackPolicies { @() }
        Mock New-CaPackPolicy {
            param($Policy)
            [pscustomobject]@{ id = [guid]::NewGuid().ToString(); displayName = $Policy.displayName }
        }
    }

    Context 'Happy path against the shipped templates' {
        It 'creates six policies when no extra switch is supplied' {
            $output = & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -Apply -Confirm:$false
            $output.Count | Should -Be 6
            @($output | Where-Object { $_.Result -ne 'Created' }).Count | Should -Be 0
            Should -Invoke New-CaPackPolicy -Times 6 -Exactly

            # The tenant id this script was given must reach Connect-CaPackGraph unchanged.
            Should -Invoke Connect-CaPackGraph -Times 1 -Exactly -ParameterFilter { $TenantId -eq $script:TenantId }

            # Every created policy must be report-only, exclude the break-glass group, and
            # carry no unresolved placeholder token.
            Should -Invoke New-CaPackPolicy -Times 6 -Exactly -ParameterFilter {
                $bodyJson = $Policy | ConvertTo-Json -Depth 10 -Compress
                $Policy.state -eq 'enabledForReportingButNotEnforced' -and
                (@($Policy.conditions.users.excludeGroups) -contains $script:BreakGlassGroupId) -and
                (-not $bodyJson.Contains('{{'))
            }
        }

        It 'creates eight policies when both licence switches are supplied' {
            $output = & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -IncludeP2 -IncludePhishingResistant -Apply -Confirm:$false
            $output.Count | Should -Be 8
            @($output | Where-Object { $_.Result -ne 'Created' }).Count | Should -Be 0
            Should -Invoke New-CaPackPolicy -Times 8 -Exactly
        }

        It 'outputs exactly Name, Action, Result, and PolicyId' {
            $output = & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -Apply -Confirm:$false
            $properties = $output[0].PSObject.Properties.Name
            $properties | Should -Be @('Name', 'Action', 'Result', 'PolicyId')
        }
    }

    Context 'Duplicate skip' {
        It 'skips a template whose display name already exists, case-insensitively' {
            Mock Get-CaPackPolicies { @([pscustomobject]@{ id = 'existing-1'; displayName = 'ca002 block legacy authentication' }) }
            $output = & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -Apply -Confirm:$false -WarningAction SilentlyContinue
            $skipped = $output | Where-Object { $_.Name -eq 'CA002 Block legacy authentication' }
            $skipped.Action | Should -Be 'Skip'
            $skipped.Result | Should -Be 'Skipped'
            $skipped.PolicyId | Should -Be 'existing-1'
            @($output | Where-Object { $_.Result -eq 'Created' }).Count | Should -Be 5
            Should -Invoke New-CaPackPolicy -Times 5 -Exactly
        }
    }

    Context 'Gather and plan checks fail with zero writes' {
        It 'fails when a template fails schema validation' {
            $root = New-CaPackFixturePack -Root (Join-Path 'TestDrive:' 'bad-schema') -TemplateJson '{"displayName":"CA901 Test template","state":"enabledForReportingButNotEnforced"}'
            { & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -TemplatePath $root -Apply -Confirm:$false } | Should -Throw '*schema validation*'
            Should -Invoke New-CaPackPolicy -Times 0 -Exactly
        }

        It 'fails when the file has been tampered with to an enforced state' {
            $tamperedJson = '{"displayName":"CA901 Test template","state":"enabled","conditions":{"applications":{"includeApplications":["All"]},"users":{"includeUsers":["All"],"excludeGroups":["{{BREAK_GLASS_GROUP_ID}}"]},"clientAppTypes":["all"]},"grantControls":{"operator":"OR","builtInControls":["mfa"]}}'
            $root = New-CaPackFixturePack -Root (Join-Path 'TestDrive:' 'tampered-state') -TemplateJson $tamperedJson
            { & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -TemplatePath $root -Apply -Confirm:$false } | Should -Throw '*schema validation*'
            Should -Invoke New-CaPackPolicy -Times 0 -Exactly
        }

        It 'fails with a clear message when a template needs -TrustedLocationId and it was not supplied' {
            $root = New-CaPackFixturePack -Root (Join-Path 'TestDrive:' 'location-required') -TemplateJson $script:LocationTemplateJson
            { & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -TemplatePath $root -Apply -Confirm:$false } | Should -Throw '*TRUSTED_LOCATION_ID*TrustedLocationId*'
            Should -Invoke New-CaPackPolicy -Times 0 -Exactly
        }

        It 'fails when the break-glass group does not exist' {
            Mock Get-CaPackGroup { $null }
            $root = New-CaPackFixturePack -Root (Join-Path 'TestDrive:' 'group-missing') -TemplateJson $script:ValidTemplateJson
            { & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -TemplatePath $root -Apply -Confirm:$false } | Should -Throw '*was not found*'
            Should -Invoke New-CaPackPolicy -Times 0 -Exactly
        }

        It 'fails when the break-glass group is not security-enabled' {
            Mock Get-CaPackGroup { [pscustomobject]@{ id = $GroupId; displayName = 'Break Glass'; securityEnabled = $false } }
            $root = New-CaPackFixturePack -Root (Join-Path 'TestDrive:' 'group-not-security-enabled') -TemplateJson $script:ValidTemplateJson
            { & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -TemplatePath $root -Apply -Confirm:$false } | Should -Throw '*not security-enabled*'
            Should -Invoke New-CaPackPolicy -Times 0 -Exactly
        }

        It 'fails when the break-glass group has zero members' {
            Mock Get-CaPackGroupMemberCount { 0 }
            $root = New-CaPackFixturePack -Root (Join-Path 'TestDrive:' 'group-zero-members') -TemplateJson $script:ValidTemplateJson
            { & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -TemplatePath $root -Apply -Confirm:$false } | Should -Throw '*no members*'
            Should -Invoke New-CaPackPolicy -Times 0 -Exactly
        }

        It 'fails when the referenced named location does not exist' {
            Mock Get-CaPackNamedLocation { $null }
            $root = New-CaPackFixturePack -Root (Join-Path 'TestDrive:' 'location-missing') -TemplateJson $script:LocationTemplateJson
            { & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -TemplatePath $root -TrustedLocationId $script:TrustedLocationId -Apply -Confirm:$false } | Should -Throw '*Named location*not found*'
            Should -Invoke New-CaPackPolicy -Times 0 -Exactly
        }
    }

    Context '-WhatIf writes nothing' {
        It 'prints the plan and calls New-CaPackPolicy zero times under -WhatIf' {
            $output = & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -Apply -WhatIf
            $output.Count | Should -Be 6
            @($output | Where-Object { $_.Result -ne 'Planned' }).Count | Should -Be 0
            Should -Invoke New-CaPackPolicy -Times 0 -Exactly
        }

        It 'prints the plan and calls New-CaPackPolicy zero times without -Apply' {
            $output = & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId
            $output.Count | Should -Be 6
            Should -Invoke New-CaPackPolicy -Times 0 -Exactly
        }
    }

    Context 'A write failure stops the run' {
        It 'leaves earlier policies created, reports the failing one Failed, marks the rest NotAttempted, and writes an error summary' {
            Mock New-CaPackPolicy {
                param($Policy)
                [pscustomobject]@{ id = [guid]::NewGuid().ToString(); displayName = $Policy.displayName }
            }
            Mock New-CaPackPolicy {
                throw 'Graph returned 400 Bad Request.'
            } -ParameterFilter { $Policy.displayName -eq 'CA001 Require MFA for all users' }

            $output = & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -Apply -Confirm:$false -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -ErrorVariable scriptErrors

            # Manifest order for the six default templates is CA002, CA003, CA001, CA005,
            # CA004, CA006, so CA001 is the third one attempted.
            $output.Count | Should -Be 6
            $output[0].Name | Should -Be 'CA002 Block legacy authentication'
            $output[0].Result | Should -Be 'Created'
            $output[1].Name | Should -Be 'CA003 Require MFA for admins'
            $output[1].Result | Should -Be 'Created'
            $output[2].Name | Should -Be 'CA001 Require MFA for all users'
            $output[2].Result | Should -Be 'Failed'
            $output[2].PolicyId | Should -BeNullOrEmpty
            @($output[3..5] | Where-Object { $_.Result -ne 'NotAttempted' }).Count | Should -Be 0
            Should -Invoke New-CaPackPolicy -Times 3 -Exactly

            $scriptErrors.Count | Should -BeGreaterThan 0
            $errorText = ($scriptErrors | ForEach-Object { $_.ToString() }) -join "`n"
            $errorText | Should -Match 'CA002 Block legacy authentication'
            $errorText | Should -Match 'CA003 Require MFA for admins'
        }
    }

    Context '-Include and -Exclude filters' {
        It 'includes only the named templates' {
            $output = & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -Include 'CA001', 'CA002'
            $output.Count | Should -Be 2
            ($output.Name | Sort-Object) | Should -Be @('CA001 Require MFA for all users', 'CA002 Block legacy authentication')
        }

        It 'excludes the named templates' {
            $output = & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -Exclude 'CA001'
            $output.Count | Should -Be 5
            $output.Name | Should -Not -Contain 'CA001 Require MFA for all users'
        }

        It 'matches include and exclude ids case-insensitively' {
            $output = & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -Include 'ca001'
            $output.Count | Should -Be 1
            $output[0].Name | Should -Be 'CA001 Require MFA for all users'
        }

        It 'throws a terminating error naming an unknown -Include id' {
            { & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -Include 'CA999' } | Should -Throw '*CA999*'
            Should -Invoke New-CaPackPolicy -Times 0 -Exactly
        }

        It 'throws a terminating error naming the gating switch when a gated id is included without it' {
            { & $script:ScriptPath -TenantId $script:TenantId -BreakGlassGroupId $script:BreakGlassGroupId -Include 'CA007' } | Should -Throw '*CA007*IncludeP2*'
            Should -Invoke New-CaPackPolicy -Times 0 -Exactly
        }
    }
}

Describe 'Connect-CaPackGraph session reuse' {
    # Exercises the real Connect-CaPackGraph (dot-sourced in the file-level BeforeAll above),
    # mocking only the three Microsoft Graph cmdlets it calls, so the tenant and auth-type
    # reuse rule in CaPack.Graph.ps1 is tested directly rather than through the mocked wrapper
    # used by the 'Import-CaPolicyPack' Describe above.

    BeforeAll {
        $script:ReuseScopes = @('Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess')
        $script:TenantA = '33333333-3333-3333-3333-333333333333'
        $script:TenantB = '44444444-4444-4444-4444-444444444444'
    }

    BeforeEach {
        Mock Connect-MgGraph { }
        Mock Disconnect-MgGraph { }
    }

    It 'reuses a delegated session already in the required tenant with every required scope' {
        Mock Get-MgContext { [pscustomobject]@{ Scopes = $script:ReuseScopes; AuthType = 'Delegated'; TenantId = $script:TenantA } }

        $result = Connect-CaPackGraph -Scopes $script:ReuseScopes -TenantId $script:TenantA

        $result | Should -BeFalse
        Should -Invoke Connect-MgGraph -Times 0 -Exactly
        Should -Invoke Disconnect-MgGraph -Times 0 -Exactly
    }

    It 'disconnects and reconnects when the existing session is app-only' {
        Mock Get-MgContext { [pscustomobject]@{ Scopes = $script:ReuseScopes; AuthType = 'AppOnly'; TenantId = $script:TenantA } }

        $result = Connect-CaPackGraph -Scopes $script:ReuseScopes -TenantId $script:TenantA

        $result | Should -BeTrue
        Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $TenantId -eq $script:TenantA }
    }

    It 'disconnects and reconnects when the existing session is connected to a different tenant' {
        Mock Get-MgContext { [pscustomobject]@{ Scopes = $script:ReuseScopes; AuthType = 'Delegated'; TenantId = $script:TenantB } }

        $result = Connect-CaPackGraph -Scopes $script:ReuseScopes -TenantId $script:TenantA

        $result | Should -BeTrue
        Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $TenantId -eq $script:TenantA }
    }

    It 'disconnects and reconnects when the existing session is missing a required scope' {
        Mock Get-MgContext { [pscustomobject]@{ Scopes = @('Policy.Read.All'); AuthType = 'Delegated'; TenantId = $script:TenantA } }

        $result = Connect-CaPackGraph -Scopes $script:ReuseScopes -TenantId $script:TenantA

        $result | Should -BeTrue
        Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $TenantId -eq $script:TenantA }
    }

    It 'connects fresh when there is no existing session, without disconnecting first' {
        Mock Get-MgContext { $null }

        $result = Connect-CaPackGraph -Scopes $script:ReuseScopes -TenantId $script:TenantA

        $result | Should -BeTrue
        Should -Invoke Disconnect-MgGraph -Times 0 -Exactly
        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $TenantId -eq $script:TenantA }
    }
}

Describe 'CaPack.Graph retry behavior' {
    # Exercises the real New-CaPackPolicy and Get-CaPackGroup (dot-sourced above), mocking only
    # Invoke-MgGraphRequest, so Invoke-CaPackGraphRetryable's 429/503-only retry rule is tested
    # directly instead of through a wrapper mock that would hide it.

    BeforeEach {
        # The real retry delay is seconds; mocking Start-Sleep keeps these tests fast without
        # changing the retry decision being tested.
        Mock Start-Sleep { }
    }

    It 'retries New-CaPackPolicy once on HTTP 429 and returns the created policy' {
        $script:callCount = 0
        Mock Invoke-MgGraphRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                throw 'Too many requests (429)'
            }
            [pscustomobject]@{ id = 'new-policy-id'; displayName = 'Test policy' }
        }

        $result = New-CaPackPolicy -Policy ([pscustomobject]@{ displayName = 'Test policy' })

        $result.id | Should -Be 'new-policy-id'
        Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'does not retry New-CaPackPolicy on a transient network error, since the POST may already have succeeded' {
        Mock Invoke-MgGraphRequest { throw [System.Net.Http.HttpRequestException]::new('Connection reset by peer') }

        { New-CaPackPolicy -Policy ([pscustomobject]@{ displayName = 'Test policy' }) } | Should -Throw '*Connection reset*'
        Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'does not retry New-CaPackPolicy on a non-throttling HTTP error such as 400' {
        Mock Invoke-MgGraphRequest { throw 'Bad Request (400)' }

        { New-CaPackPolicy -Policy ([pscustomobject]@{ displayName = 'Test policy' }) } | Should -Throw '*400*'
        Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'retries Get-CaPackGroup on HTTP 503 and returns the group' {
        $script:callCount = 0
        Mock Invoke-MgGraphRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                throw 'Service unavailable (503)'
            }
            [pscustomobject]@{ id = 'group-1'; displayName = 'Group'; securityEnabled = $true }
        }

        $result = Get-CaPackGroup -GroupId 'group-1'

        $result.id | Should -Be 'group-1'
        Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'still returns $null from Get-CaPackGroup on a 404 without retrying' {
        Mock Invoke-MgGraphRequest { throw 'Not Found (404)' }

        $result = Get-CaPackGroup -GroupId 'missing-group'

        $result | Should -BeNullOrEmpty
        Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'gives up after the retry budget is exhausted and rethrows' {
        Mock Invoke-MgGraphRequest { throw 'Too many requests (429)' }

        { New-CaPackPolicy -Policy ([pscustomobject]@{ displayName = 'Test policy' }) -ErrorAction Stop } | Should -Throw '*429*'
        # Default MaxRetries is 4: one original attempt plus four retries equals five calls.
        Should -Invoke Invoke-MgGraphRequest -Times 5 -Exactly
    }
}
