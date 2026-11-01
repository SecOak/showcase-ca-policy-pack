#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
<#
.SYNOPSIS
    Validates the repository scaffold files.
.DESCRIPTION
    Checks that PSScriptAnalyzerSettings.psd1 loads as valid PowerShell data and has the expected
    shape, and that the git hook enabler script parses without syntax errors.
.NOTES
    Author: Sec Oak
#>

Set-StrictMode -Version Latest

Describe 'PSScriptAnalyzer settings' {

    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:SettingsPath = Join-Path $script:RepoRoot 'PSScriptAnalyzerSettings.psd1'
    }

    It 'loads as a PowerShell data file' {
        { Import-PowerShellDataFile -Path $script:SettingsPath } | Should -Not -Throw
    }

    It 'sets Warning and Error severity' {
        $settings = Import-PowerShellDataFile -Path $script:SettingsPath
        $settings.Severity | Should -Contain 'Warning'
        $settings.Severity | Should -Contain 'Error'
    }

    It 'does not exclude PSAvoidUsingWriteHost' {
        $settings = Import-PowerShellDataFile -Path $script:SettingsPath
        $settings.ExcludeRules | Should -Not -Contain 'PSAvoidUsingWriteHost'
    }
}

Describe 'Git hooks' {

    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:EnablerPath = Join-Path $script:RepoRoot 'tools\Enable-GitHooks.ps1'
    }

    It 'Enable-GitHooks.ps1 exists' {
        Test-Path -Path $script:EnablerPath | Should -BeTrue
    }

    It 'Enable-GitHooks.ps1 parses without syntax errors' {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:EnablerPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
        $parseErrors.Count | Should -Be 0
    }

    It 'pre-commit hook file exists' {
        Test-Path -Path (Join-Path $script:RepoRoot '.githooks\pre-commit') | Should -BeTrue
    }
}
