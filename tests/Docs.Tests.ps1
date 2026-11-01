#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
<#
.SYNOPSIS
    Validates the operator-facing documents.
.DESCRIPTION
    Checks that README.md and DEPLOYMENT-ORDER.md mention every template in manifest.json,
    that README.md mentions every delegated Microsoft Graph scope the import script asks for,
    and that no Markdown file in the repository contains an em dash or an overclaiming phrase.
.NOTES
    Author: Sec Oak
#>

Set-StrictMode -Version Latest

BeforeDiscovery {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ManifestPath = Join-Path $script:RepoRoot 'manifest.json'
    $script:Manifest = Get-Content -Path $script:ManifestPath -Raw | ConvertFrom-Json
    # Also discovery-time, for the same reason as the manifest above: the -ForEach lists below
    # are built from it.
    $script:MarkdownFiles = Get-ChildItem -Path $script:RepoRoot -Recurse -File -Filter '*.md' -Force |
        Where-Object { $_.FullName -notmatch '(?:^|[\\/])\.git(?:[\\/]|$)' }
    # Also discovery-time: the 'Delegated scopes' Context below uses this list with -ForEach,
    # and -ForEach is evaluated during discovery, not during the run phase.
    $script:ExpectedScopes = @(
        'Policy.Read.All'
        'Policy.ReadWrite.ConditionalAccess'
        'GroupMember.Read.All'
    )
}

Describe 'Operator documents' {

    BeforeAll {
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:Manifest = Get-Content -Path (Join-Path $script:RepoRoot 'manifest.json') -Raw | ConvertFrom-Json
        $script:ReadmeText = Get-Content -Path (Join-Path $script:RepoRoot 'README.md') -Raw
        $script:DeploymentOrderText = Get-Content -Path (Join-Path $script:RepoRoot 'DEPLOYMENT-ORDER.md') -Raw

        # Phrases that would overclaim what this pack does, never allowed in a Markdown file.
        $script:ForbiddenPhrases = @(
            'secure your tenant'
            'fully compliant'
            'guaranteed'
        )
    }

    Context 'Template coverage' {
        It 'README.md mentions <_.id>' -ForEach $script:Manifest.templates {
            $script:ReadmeText | Should -Match ([regex]::Escape($_.id))
        }

        It 'DEPLOYMENT-ORDER.md mentions <_.id>' -ForEach $script:Manifest.templates {
            $script:DeploymentOrderText | Should -Match ([regex]::Escape($_.id))
        }
    }

    Context 'Enable order table' {
        It 'DEPLOYMENT-ORDER.md enable order table lists every manifest template exactly once' {
            $tableIds = [regex]::Matches($script:DeploymentOrderText, '(?m)^\|\s*\d+\s*\|\s*(CA\d{3})') |
                ForEach-Object { $_.Groups[1].Value }
            $expectedIds = $script:Manifest.templates.id

            $tableIds.Count | Should -Be $expectedIds.Count -Because 'the table should have exactly one row per manifest template'
            ($tableIds | Sort-Object -Unique).Count | Should -Be $tableIds.Count -Because 'no template id should repeat in the table'
            foreach ($id in $expectedIds) {
                $tableIds | Should -Contain $id -Because "manifest template $id should appear in the enable order table"
            }
        }
    }

    Context 'Delegated scopes' {
        It 'README.md mentions the <_> scope' -ForEach $script:ExpectedScopes {
            $script:ReadmeText | Should -Match ([regex]::Escape($_))
        }
    }

    Context 'No em dashes in Markdown' {
        It 'contains no em dash in <_.FullName>' -ForEach $script:MarkdownFiles {
            $content = Get-Content -Path $_.FullName -Raw
            if ($null -eq $content) {
                $content = ''
            }
            $content.Contains([string][char]0x2014) | Should -BeFalse
        }
    }

    Context 'No overclaiming phrases in Markdown' {
        It 'contains no forbidden phrase in <_.FullName>' -ForEach $script:MarkdownFiles {
            $content = Get-Content -Path $_.FullName -Raw
            if ($null -eq $content) {
                $content = ''
            }
            foreach ($phrase in $script:ForbiddenPhrases) {
                $content.IndexOf($phrase, [System.StringComparison]::OrdinalIgnoreCase) |
                    Should -Be -1 -Because "found the phrase '$phrase'"
            }
        }
    }
}
