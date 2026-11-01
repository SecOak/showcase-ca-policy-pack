#Requires -Version 7.0
<#
.SYNOPSIS
    Configures this clone of the repository to run its git hooks.
.DESCRIPTION
    Sets the local git config value core.hooksPath to .githooks, so the pre-commit
    gitleaks secret scan runs automatically on every commit made from this clone.
    This is a one-time, per-clone setting; it is not stored in the repository itself
    because git does not allow a repository to set its own hooksPath automatically.
.EXAMPLE
    .\tools\Enable-GitHooks.ps1

    Enables the repository's git hooks for the current clone.
.NOTES
    Author: Sec Oak
    No network access and no Microsoft Graph permissions are required.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$repoRoot = git rev-parse --show-toplevel 2>$null
if (-not $repoRoot) {
    throw 'Enable-GitHooks.ps1 must be run from inside a clone of the repository.'
}

git config core.hooksPath .githooks

Write-Verbose 'core.hooksPath set to .githooks for this clone.'
