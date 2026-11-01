#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
<#
.SYNOPSIS
    Tests Export-CaBaseline.ps1 against mocked Microsoft Graph reads.
.DESCRIPTION
    Dot-sources the script itself (not just the helpers it uses) inside each test, after
    mocking Connect-MgGraph, Get-MgContext, Disconnect-MgGraph, and Invoke-MgGraphRequest, so
    the script's own main body runs against fake data and writes to a TestDrive folder. Covers
    paging (two mocked pages joined into one file set), safe file names for odd display names,
    the returned summary object, and that no account name or token ever lands in a written
    file.
.NOTES
    Author: Sec Oak
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:RepoRoot 'Export-CaBaseline.ps1'

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

Describe 'Export-CaBaseline.ps1' {

    BeforeEach {
        $script:OutputPath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Mock Get-MgContext { [pscustomobject]@{ TenantId = '55555555-5555-5555-5555-555555555555'; Account = 'someone@example.com'; Scopes = @('Policy.Read.All') } }
        Mock Connect-MgGraph { }
        Mock Disconnect-MgGraph { }
        Mock Write-Warning { }
    }

    Context 'paging' {
        It 'joins two mocked policy pages into one file per policy' {
            Mock Invoke-MgGraphRequest {
                param($Uri)
                if ($Uri -like '*conditionalAccess/policies*') {
                    if ($Uri -eq '/identity/conditionalAccess/policies') {
                        return [pscustomobject]@{
                            value           = @([pscustomobject]@{ id = 'p1'; displayName = 'Policy One'; state = 'enabledForReportingButNotEnforced' })
                            '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?page=2'
                        }
                    }
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'p2'; displayName = 'Policy Two'; state = 'enabledForReportingButNotEnforced' }) }
                }
                [pscustomobject]@{ value = @() }
            }

            $result = . $script:ScriptPath -OutputPath $script:OutputPath

            $result.PolicyCount | Should -Be 2
            (Get-ChildItem -Path (Join-Path $script:OutputPath 'policies') -Filter '*.json').Count | Should -Be 2
        }
    }

    Context 'safe file names' {
        It 'sanitises a display name with characters Windows disallows in file names' {
            Mock Invoke-MgGraphRequest {
                param($Uri)
                if ($Uri -eq '/identity/conditionalAccess/policies') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'p1'; displayName = 'My/Policy:Test*Name?'; state = 'enabled' }) }
                }
                [pscustomobject]@{ value = @() }
            }

            . $script:ScriptPath -OutputPath $script:OutputPath | Out-Null

            $files = @(Get-ChildItem -Path (Join-Path $script:OutputPath 'policies') -Filter '*.json')
            $files.Count | Should -Be 1
            $files[0].Name | Should -Not -Match '[\\/:*?"<>|]'
        }

        It 'de-duplicates two policies that sanitise to the same file name' {
            Mock Invoke-MgGraphRequest {
                param($Uri)
                if ($Uri -eq '/identity/conditionalAccess/policies') {
                    return [pscustomobject]@{
                        value = @(
                            [pscustomobject]@{ id = 'p1'; displayName = 'Same/Name'; state = 'enabled' }
                            [pscustomobject]@{ id = 'p2'; displayName = 'Same:Name'; state = 'enabled' }
                        )
                    }
                }
                [pscustomobject]@{ value = @() }
            }

            $result = . $script:ScriptPath -OutputPath $script:OutputPath

            $result.PolicyCount | Should -Be 2
            (Get-ChildItem -Path (Join-Path $script:OutputPath 'policies') -Filter '*.json').Count | Should -Be 2
        }

        It 'falls back to a usable name for a display name with nothing left after sanitising' {
            Mock Invoke-MgGraphRequest {
                param($Uri)
                if ($Uri -eq '/identity/conditionalAccess/policies') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'p1'; displayName = '???'; state = 'enabled' }) }
                }
                [pscustomobject]@{ value = @() }
            }

            . $script:ScriptPath -OutputPath $script:OutputPath | Out-Null

            $files = @(Get-ChildItem -Path (Join-Path $script:OutputPath 'policies') -Filter '*.json')
            $files.Count | Should -Be 1
            $files[0].BaseName | Should -Be 'policy'
        }
    }

    Context 'written files and the returned summary' {
        BeforeEach {
            Mock Invoke-MgGraphRequest {
                param($Uri)
                if ($Uri -eq '/identity/conditionalAccess/policies') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'p1'; displayName = 'Policy One'; state = 'enabled' }) }
                }
                if ($Uri -eq '/identity/conditionalAccess/namedLocations') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'nl1'; displayName = 'Trusted range' }) }
                }
                if ($Uri -eq '/policies/authenticationStrengthPolicies') {
                    return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'as1'; displayName = 'Phishing-resistant MFA' }) }
                }
                [pscustomobject]@{ value = @() }
            }
        }

        It 'returns OutputPath, PolicyCount, NamedLocationCount, and AuthenticationStrengthCount' {
            $result = . $script:ScriptPath -OutputPath $script:OutputPath

            $result.OutputPath | Should -Be $script:OutputPath
            $result.PolicyCount | Should -Be 1
            $result.NamedLocationCount | Should -Be 1
            $result.AuthenticationStrengthCount | Should -Be 1
        }

        It 'writes namedLocations.json, authenticationStrengths.json, and export.json' {
            . $script:ScriptPath -OutputPath $script:OutputPath | Out-Null

            Test-Path (Join-Path $script:OutputPath 'namedLocations.json') | Should -BeTrue
            Test-Path (Join-Path $script:OutputPath 'authenticationStrengths.json') | Should -BeTrue
            Test-Path (Join-Path $script:OutputPath 'export.json') | Should -BeTrue
        }

        It 'writes an export.json summary with the tenant id, counts, and a script version, and no account name' {
            . $script:ScriptPath -OutputPath $script:OutputPath | Out-Null

            $summary = Get-Content -Path (Join-Path $script:OutputPath 'export.json') -Raw | ConvertFrom-Json
            $summary.tenantId | Should -Be '55555555-5555-5555-5555-555555555555'
            $summary.policyCount | Should -Be 1
            $summary.namedLocationCount | Should -Be 1
            $summary.authenticationStrengthCount | Should -Be 1
            $summary.scriptVersion | Should -Not -BeNullOrEmpty
            ($summary.PSObject.Properties.Name) | Should -Not -Contain 'account'
        }

        It 'warns exactly once that the output folder contains tenant data' {
            . $script:ScriptPath -OutputPath $script:OutputPath | Out-Null

            Should -Invoke Write-Warning -Times 1 -Exactly
        }

        It 'never writes the mocked account name or a token-shaped value to any file it creates' {
            . $script:ScriptPath -OutputPath $script:OutputPath | Out-Null

            $writtenFiles = Get-ChildItem -Path $script:OutputPath -Recurse -File
            foreach ($file in $writtenFiles) {
                $content = Get-Content -Path $file.FullName -Raw
                $content | Should -Not -Match 'someone@example\.com'
                $content | Should -Not -Match 'AccessToken'
            }
        }
    }

    Context 'empty tenant' {
        BeforeEach {
            Mock Invoke-MgGraphRequest {
                [pscustomobject]@{ value = @() }
            }
        }

        It 'reports a PolicyCount, NamedLocationCount, and AuthenticationStrengthCount of 0, and still writes files holding empty arrays' {
            $result = . $script:ScriptPath -OutputPath $script:OutputPath

            $result.PolicyCount | Should -Be 0
            $result.NamedLocationCount | Should -Be 0
            $result.AuthenticationStrengthCount | Should -Be 0

            Test-Path (Join-Path $script:OutputPath 'policies') | Should -BeTrue
            (@(Get-ChildItem -Path (Join-Path $script:OutputPath 'policies') -Filter '*.json')).Count | Should -Be 0

            Test-Path (Join-Path $script:OutputPath 'namedLocations.json') | Should -BeTrue
            Test-Path (Join-Path $script:OutputPath 'authenticationStrengths.json') | Should -BeTrue
            (Get-Content -Path (Join-Path $script:OutputPath 'namedLocations.json') -Raw).Trim() | Should -Be '[]'
            (Get-Content -Path (Join-Path $script:OutputPath 'authenticationStrengths.json') -Raw).Trim() | Should -Be '[]'

            $summary = Get-Content -Path (Join-Path $script:OutputPath 'export.json') -Raw | ConvertFrom-Json
            $summary.policyCount | Should -Be 0
            $summary.namedLocationCount | Should -Be 0
            $summary.authenticationStrengthCount | Should -Be 0
        }
    }
}
