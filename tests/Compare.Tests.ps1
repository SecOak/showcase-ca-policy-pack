#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
<#
.SYNOPSIS
    Tests Compare-CaBaseline.ps1 against a fixture baseline and against mocked live reads.
.DESCRIPTION
    Dot-sources the script itself inside each test, pointed at
    tests\fixtures\baseline-sample (invented policies and templates with placeholder GUIDs,
    never real tenant data), covering every Status value the script can produce: Missing,
    Matches (including an array that is reordered but still matches), Differs (a field
    difference deep in conditions.users), ReportOnly and Enabled (a policy that differs from
    its template only in state), and NotInPack. Also covers CSV output and the live-tenant
    path with Connect-MgGraph, Get-MgContext, and Invoke-MgGraphRequest mocked.
.NOTES
    Author: Sec Oak
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:RepoRoot 'Compare-CaBaseline.ps1'
    $script:FixturePath = Join-Path $script:RepoRoot 'tests\fixtures\baseline-sample'
    $script:FixtureTemplatePath = Join-Path $script:FixturePath 'templates'
    $script:BreakGlassGroupId = '99999999-9999-9999-9999-999999999999'

    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        # Microsoft.Graph.Authentication is not installed on this machine. Define stubs with the
        # same names so Mock has commands to attach to; the script under test never calls the
        # real module, only these names, so the stubs themselves are never exercised.
        function Invoke-MgGraphRequest {
            [CmdletBinding()]
            param([Parameter()][string]$Method, [Parameter()][string]$Uri, [Parameter()][string]$OutputType)
            throw "Invoke-MgGraphRequest stub was called directly with Method='$Method' Uri='$Uri' OutputType='$OutputType'; it should always be mocked in tests."
        }
        function Connect-MgGraph {
            [CmdletBinding()]
            param([Parameter()][string[]]$Scopes, [Parameter()][string]$ContextScope, [Parameter()][switch]$NoWelcome)
            throw "Connect-MgGraph stub was called directly with Scopes='$Scopes' ContextScope='$ContextScope' NoWelcome='$NoWelcome'; it should always be mocked in tests."
        }
        function Get-MgContext {
            [CmdletBinding()]
            param()
            throw 'Get-MgContext stub was called directly; it should always be mocked in tests.'
        }
        function Disconnect-MgGraph {
            [CmdletBinding()]
            param()
            throw 'Disconnect-MgGraph stub was called directly; it should always be mocked in tests.'
        }
    }
}

Describe 'Compare-CaBaseline.ps1 against a baseline export folder' {

    BeforeEach {
        $script:Results = . $script:ScriptPath -TemplatePath $script:FixtureTemplatePath -BaselinePath $script:FixturePath -BreakGlassGroupId $script:BreakGlassGroupId
    }

    It 'reports a template with no live policy as Missing' {
        $row = $script:Results | Where-Object { $_.Template -eq 'FIX5 Missing sample' }
        $row.Status | Should -Be 'Missing'
        $row.Path | Should -Be ''
    }

    It 'reports a policy identical to its template, apart from a reordered array, as Matches' {
        $row = $script:Results | Where-Object { $_.Template -eq 'FIX1 Matches sample' }
        $row.Status | Should -Be 'Matches'
        $row.State | Should -Be 'enabledForReportingButNotEnforced'
        $row.Path | Should -Be ''
    }

    It 'reports a field difference deep in conditions.users as Differs, naming the first difference' {
        $row = $script:Results | Where-Object { $_.Template -eq 'FIX2 Differs sample' }
        $row.Status | Should -Be 'Differs'
        $row.Path | Should -Match '^conditions\.users\.'
    }

    It 'reports a policy that differs from its template only by being disabled as Disabled' {
        $row = $script:Results | Where-Object { $_.Template -eq 'FIX3 Disabled sample' }
        $row.Status | Should -Be 'Disabled'
        $row.State | Should -Be 'disabled'
        $row.Path | Should -Be ''
    }

    It 'reports a policy whose live state is report-only but does not match the template state, and is not enabled or disabled, as ReportOnly' {
        $row = $script:Results | Where-Object { $_.Template -eq 'FIX6 ReportOnly sample' }
        $row.Status | Should -Be 'ReportOnly'
        $row.State | Should -Be 'enabledForReportingButNotEnforced'
        $row.Path | Should -Be ''
    }

    It 'reports a policy that differs from its template only by being enabled as Enabled' {
        $row = $script:Results | Where-Object { $_.Template -eq 'FIX4 Enabled sample' }
        $row.Status | Should -Be 'Enabled'
        $row.State | Should -Be 'enabled'
        $row.Path | Should -Be ''
    }

    It 'reports a live policy with no matching template as NotInPack' {
        $row = $script:Results | Where-Object { $_.Template -eq 'FIX9 Not in pack' }
        $row.Status | Should -Be 'NotInPack'
        $row.State | Should -Be 'enabled'
    }

    It 'reports a second live policy sharing a display name as an additional NotInPack row naming the duplicate' {
        $rows = @($script:Results | Where-Object { $_.Template -eq 'FIX7 Duplicate sample' })
        $rows.Count | Should -Be 2

        $firstRow = $rows | Where-Object { $_.Path -eq '' }
        $firstRow.Status | Should -Be 'NotInPack'

        $duplicateRow = $rows | Where-Object { $_.Path -eq 'displayName' }
        $duplicateRow.Status | Should -Be 'NotInPack'
        $duplicateRow.Actual | Should -Match 'bbbbbbbb-0000-0000-0000-000000000008'
    }

    It 'resolves the break-glass group id back to its placeholder before comparing, so it is never reported as a difference' {
        $row = $script:Results | Where-Object { $_.Template -eq 'FIX1 Matches sample' }
        $row.Status | Should -Be 'Matches'
    }

    It 'always exits successfully even though some templates differ' {
        $script:Results | Where-Object { $_.Status -eq 'Differs' } | Should -Not -BeNullOrEmpty

        # $LASTEXITCODE is only ever set by a real external process, never by dot-sourcing a
        # script in this same session, so this assertion runs the script as a genuine child
        # pwsh process (no mocking needed: -BaselinePath means it never touches live Graph).
        & pwsh -NoProfile -Command "& '$($script:ScriptPath)' -TemplatePath '$($script:FixtureTemplatePath)' -BaselinePath '$($script:FixturePath)' -BreakGlassGroupId '$($script:BreakGlassGroupId)'" | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Compare-CaBaseline.ps1 CSV output' {
    It 'writes every result to the CSV path' {
        $csvPath = Join-Path $TestDrive 'drift.csv'

        . $script:ScriptPath -TemplatePath $script:FixtureTemplatePath -BaselinePath $script:FixturePath -BreakGlassGroupId $script:BreakGlassGroupId -CsvPath $csvPath | Out-Null

        Test-Path $csvPath | Should -BeTrue
        $rows = Import-Csv -Path $csvPath
        ($rows | Where-Object { $_.Template -eq 'FIX1 Matches sample' }).Status | Should -Be 'Matches'
        ($rows | Where-Object { $_.Template -eq 'FIX2 Differs sample' }).Status | Should -Be 'Differs'
        $rows.Count | Should -Be 9
    }
}

Describe 'Compare-CaBaseline.ps1 against the live tenant' {
    It 'reads policies from Microsoft Graph when -BaselinePath is omitted' {
        # No existing session, so Connect-CaPackGraphReadOnly actually calls Connect-MgGraph
        # instead of reusing one, which this test verifies below.
        Mock Get-MgContext { $null }
        Mock Connect-MgGraph { }
        Mock Disconnect-MgGraph { }
        Mock Invoke-MgGraphRequest {
            param($Uri)
            if ($Uri -eq '/identity/conditionalAccess/policies') {
                return [pscustomobject]@{
                    value = @([pscustomobject]@{
                        id          = 'live1'
                        displayName = 'FIX1 Matches sample'
                        state       = 'enabledForReportingButNotEnforced'
                        conditions  = [pscustomobject]@{
                            applications = [pscustomobject]@{ includeApplications = @('All') }
                            users        = [pscustomobject]@{
                                includeRoles  = @('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111')
                                excludeGroups = @('99999999-9999-9999-9999-999999999999')
                            }
                            clientAppTypes = @('all')
                        }
                        grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @('mfa') }
                    })
                }
            }
            [pscustomobject]@{ value = @() }
        }

        $results = . $script:ScriptPath -TemplatePath $script:FixtureTemplatePath -BreakGlassGroupId $script:BreakGlassGroupId

        ($results | Where-Object { $_.Template -eq 'FIX1 Matches sample' }).Status | Should -Be 'Matches'
        ($results | Where-Object { $_.Template -eq 'FIX5 Missing sample' }).Status | Should -Be 'Missing'
        Should -Invoke Connect-MgGraph -Times 1 -Exactly
        Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
    }
}

Describe 'Compare-CaBaseline.ps1 against an empty tenant' {
    It 'reports every template as Missing when there are no live policies' {
        $emptyBaselinePath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -Path (Join-Path $emptyBaselinePath 'policies') -ItemType Directory -Force | Out-Null

        $results = . $script:ScriptPath -TemplatePath $script:FixtureTemplatePath -BaselinePath $emptyBaselinePath -BreakGlassGroupId $script:BreakGlassGroupId

        $templateFileCount = (@(Get-ChildItem -Path $script:FixtureTemplatePath -Filter '*.json' -File)).Count
        $results.Count | Should -Be $templateFileCount
        foreach ($row in $results) {
            $row.Status | Should -Be 'Missing'
        }
    }
}

Describe 'Compare-CaBaseline.ps1 against a real Microsoft Graph authenticationStrength shape' {
    It 'reduces an expanded live authenticationStrength and drops its @odata.context sibling, so CA008 reports Matches' {
        $realTemplatePath = Join-Path $script:RepoRoot 'templates'
        $ca008BreakGlassGroupId = '33333333-3333-3333-3333-333333333333'
        $ca008BaselinePath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -Path (Join-Path $ca008BaselinePath 'policies') -ItemType Directory -Force | Out-Null

        $livePolicy = [ordered]@{
            id               = 'live-ca008'
            displayName      = 'CA008 Phishing-resistant MFA for admins'
            state            = 'enabledForReportingButNotEnforced'
            createdDateTime  = '2026-01-01T00:00:00Z'
            modifiedDateTime = '2026-01-02T00:00:00Z'
            conditions       = [ordered]@{
                applications   = [ordered]@{ includeApplications = @('All') }
                users          = [ordered]@{
                    includeRoles  = @(
                        '62e90394-69f5-4237-9190-012177145e10',
                        'e8611ab8-c189-46e8-94e1-60213ab1f814',
                        '7be44c8a-adaf-4e2a-84d6-ab2649e08a13',
                        '194ae4cb-b126-40b2-bd5b-6091b380977d',
                        'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9'
                    )
                    excludeGroups = @($ca008BreakGlassGroupId)
                }
                clientAppTypes = @('all')
            }
            grantControls    = [ordered]@{
                operator                               = 'OR'
                'authenticationStrength@odata.context' = 'https://graph.microsoft.com/v1.0/$metadata#policies/authenticationStrengthPolicies/$entity'
                authenticationStrength                 = [ordered]@{
                    id                    = '00000000-0000-0000-0000-000000000004'
                    displayName           = 'Phishing-resistant MFA'
                    policyType            = 'builtIn'
                    requirementsSatisfied = 'mfa'
                    allowedCombinations   = @('windowsHelloForBusiness', 'fido2', 'x509CertificateMultiFactor')
                    createdDateTime       = '2021-12-01T08:00:00Z'
                    modifiedDateTime      = '2021-12-01T08:00:00Z'
                }
            }
        }
        $livePolicy | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $ca008BaselinePath 'policies\live.json') -Encoding utf8

        $results = . $script:ScriptPath -TemplatePath $realTemplatePath -BaselinePath $ca008BaselinePath -BreakGlassGroupId $ca008BreakGlassGroupId

        $row = $results | Where-Object { $_.Template -eq 'CA008 Phishing-resistant MFA for admins' }
        $row.Status | Should -Be 'Matches'
    }
}

Describe 'Compare-CaBaseline.ps1 parameter validation' {
    It 'rejects a BreakGlassGroupId that is not a GUID' {
        { . $script:ScriptPath -TemplatePath $script:FixtureTemplatePath -BaselinePath $script:FixturePath -BreakGlassGroupId 'not-a-guid' } | Should -Throw
    }

    It 'rejects a TrustedLocationId that is not a GUID' {
        { . $script:ScriptPath -TemplatePath $script:FixtureTemplatePath -BaselinePath $script:FixturePath -BreakGlassGroupId $script:BreakGlassGroupId -TrustedLocationId 'not-a-guid' } | Should -Throw
    }
}
