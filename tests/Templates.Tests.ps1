#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5' }
<#
.SYNOPSIS
    Validates every Conditional Access policy template and the manifest that describes them.
.DESCRIPTION
    Checks that each template file under templates\ is schema-valid, is report-only, excludes
    the break-glass placeholder, and contains only well-known, publicly documented GUIDs (built-in
    directory role template IDs and the built-in authentication strength ID), never a value that
    could be mistaken for a real tenant ID. Also checks the manifest and template files stay in
    sync, and that no file in the repository contains an em dash.
.NOTES
    Author: Sec Oak
#>

Set-StrictMode -Version Latest

BeforeDiscovery {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:TemplatesPath = Join-Path $script:RepoRoot 'templates'
    $script:SchemaPath = Join-Path $script:RepoRoot 'schema\conditionalAccessTemplate.schema.json'
    $script:ManifestPath = Join-Path $script:RepoRoot 'manifest.json'
    $script:TemplateFiles = Get-ChildItem -Path $script:TemplatesPath -Filter '*.json' -File | Sort-Object Name
    # Loaded during discovery, not Run, because the sync checks below use it with -ForEach.
    $script:Manifest = Get-Content -Path $script:ManifestPath -Raw | ConvertFrom-Json
    # Also discovery-time, for the same reason: the GUID allow-list scan below uses it with -ForEach.
    # The GUID scan covers the template files plus the two other files allowed to reference roles
    # by ID: manifest.json and README.md.
    $script:GuidScanFiles = @($script:TemplateFiles) +
        (Get-Item -Path $script:ManifestPath) +
        (Get-Item -Path (Join-Path $script:RepoRoot 'README.md'))
    # Also discovery-time, for the same reason: the em dash scan below uses it with -ForEach.
    # Every file in the repository is in scope except the .git metadata (directory or, inside a
    # worktree, the .git file at the repo root) and anything that is not text, detected by the
    # presence of a null byte rather than by file extension, so no file format is overlooked.
    $script:TextFiles = Get-ChildItem -Path $script:RepoRoot -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '(?:^|[\\/])\.git(?:[\\/]|$)' } |
        Where-Object { -not ([System.IO.File]::ReadAllBytes($_.FullName) -contains [byte]0) }
}

Describe 'Conditional Access templates' {

    BeforeAll {
        # BeforeDiscovery only runs during the discovery pass; It and BeforeAll run in a separate
        # pass, so the values needed inside It bodies (as opposed to values only needed to build
        # the -ForEach list itself) are recomputed here for the run phase.
        $script:RepoRoot = Split-Path -Parent $PSScriptRoot
        $script:SchemaPath = Join-Path $script:RepoRoot 'schema\conditionalAccessTemplate.schema.json'
        $script:Manifest = Get-Content -Path (Join-Path $script:RepoRoot 'manifest.json') -Raw | ConvertFrom-Json

        # Well-known, publicly documented GUIDs only: built-in Microsoft Entra directory role
        # template IDs and the built-in authentication strength ID named in the approved plan.
        # Any GUID found in a template that is not on this list is treated as a possible tenant
        # ID that slipped in by mistake.
        $script:AllowedGuids = @(
            '62e90394-69f5-4237-9190-012177145e10' # Global Administrator
            'e8611ab8-c189-46e8-94e1-60213ab1f814' # Privileged Role Administrator
            '7be44c8a-adaf-4e2a-84d6-ab2649e08a13' # Privileged Authentication Administrator
            '194ae4cb-b126-40b2-bd5b-6091b380977d' # Security Administrator
            'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9' # Conditional Access Administrator
            '29232cdf-9323-42fd-ade2-1d097af3e4de' # Exchange Administrator
            'f28a1f50-f6e7-4571-818b-6a12f2af6b6c' # SharePoint Administrator
            'fe930be7-5e62-47db-91af-98c3a49a38b1' # User Administrator
            'c4e39bd9-1100-46d3-8c65-fb160da0071f' # Authentication Administrator
            '729827e3-9c14-49f7-bb1b-9608f156bbb8' # Helpdesk Administrator
            'b0f54661-2d74-4c50-afa3-1ec803f12efe' # Billing Administrator
            '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3' # Application Administrator
            '158c047a-c907-4556-b7ef-446551a6b5f7' # Cloud Application Administrator
            '3a2c62db-5318-420d-8d74-23affee5d9d5' # Intune Administrator
            '966707d0-3269-4727-9be2-8c3a10f19b9d' # Password Administrator
            'd29b2b05-8046-44ba-8758-1e26182fcf32' # Directory Synchronization Accounts
            '00000000-0000-0000-0000-000000000004' # Built-in authentication strength: Phishing-resistant MFA
        )

        # Matches a standard hyphenated GUID (optionally brace-wrapped) or 32 contiguous hex
        # characters with no hyphens, so a GUID cannot slip past the allow-list just by being
        # reformatted.
        $script:GuidPattern = '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}' +
            '|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' +
            '|(?<![0-9a-fA-F])[0-9a-fA-F]{32}(?![0-9a-fA-F])'
    }

    Context 'Schema validation' {
        It 'validates <_.Name> against the template schema' -ForEach $script:TemplateFiles {
            $json = Get-Content -Path $_.FullName -Raw
            Test-Json -Json $json -SchemaFile $script:SchemaPath | Should -BeTrue
        }
    }

    Context 'Report-only state and break-glass exclusion' {
        It '<_.Name> is enabledForReportingButNotEnforced' -ForEach $script:TemplateFiles {
            $template = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
            $template.state | Should -Be 'enabledForReportingButNotEnforced'
        }

        It '<_.Name> excludes the break-glass group placeholder' -ForEach $script:TemplateFiles {
            $template = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
            $template.conditions.users.excludeGroups | Should -Contain '{{BREAK_GLASS_GROUP_ID}}'
        }

        It '<_.Name> display name starts with its template id' -ForEach $script:TemplateFiles {
            $template = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
            $expectedId = ($_.BaseName -split '-')[0]
            $template.displayName | Should -Match "^$expectedId "
        }
    }

    Context 'GUID allow-list' {
        It '<_.Name> contains only well-known GUIDs' -ForEach $script:GuidScanFiles {
            $content = Get-Content -Path $_.FullName -Raw
            $found = [regex]::Matches($content, $script:GuidPattern) | ForEach-Object {
                $normalized = $_.Value.Trim('{', '}').ToLowerInvariant()
                if ($normalized -notmatch '-') {
                    $normalized = $normalized -replace '^([0-9a-f]{8})([0-9a-f]{4})([0-9a-f]{4})([0-9a-f]{4})([0-9a-f]{12})$', '$1-$2-$3-$4-$5'
                }
                $normalized
            }
            foreach ($guid in $found) {
                $script:AllowedGuids | Should -Contain $guid -Because "$($_.Name) referenced GUID $guid, which is not on the well-known allow-list"
            }
        }
    }

    Context 'Schema rejects invalid templates' {
        BeforeAll {
            $script:GoodTemplatePath = Join-Path $script:RepoRoot 'templates\CA001-require-mfa-all-users.json'
        }

        It 'rejects a template with an extra, undeclared property' {
            $template = Get-Content -Path $script:GoodTemplatePath -Raw | ConvertFrom-Json
            $template | Add-Member -MemberType NoteProperty -Name 'notAGraphProperty' -Value 'unexpected'
            $json = $template | ConvertTo-Json -Depth 10
            Test-Json -Json $json -SchemaFile $script:SchemaPath -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects a template with state set to enabled' {
            $template = Get-Content -Path $script:GoodTemplatePath -Raw | ConvertFrom-Json
            $template.state = 'enabled'
            $json = $template | ConvertTo-Json -Depth 10
            Test-Json -Json $json -SchemaFile $script:SchemaPath -ErrorAction SilentlyContinue | Should -BeFalse
        }

        It 'rejects a template with no excludeGroups' {
            $template = Get-Content -Path $script:GoodTemplatePath -Raw | ConvertFrom-Json
            $template.conditions.users.PSObject.Properties.Remove('excludeGroups')
            $json = $template | ConvertTo-Json -Depth 10
            Test-Json -Json $json -SchemaFile $script:SchemaPath -ErrorAction SilentlyContinue | Should -BeFalse
        }
    }

    Context 'Manifest and template files stay in sync' {
        It 'has a manifest entry for every template file' -ForEach $script:TemplateFiles {
            $relativePath = "templates/$($_.Name)"
            $script:Manifest.templates.file | Should -Contain $relativePath
        }

        It 'has a template file for every manifest entry' -ForEach $script:Manifest.templates {
            $templateFilePath = Join-Path $script:RepoRoot ($_.file -replace '/', '\')
            Test-Path -Path $templateFilePath | Should -BeTrue -Because "manifest entry $($_.id) points to $($_.file)"
        }

        It 'lists every template in README.md' -ForEach $script:Manifest.templates {
            $readme = Get-Content -Path (Join-Path $script:RepoRoot 'README.md') -Raw
            $readme | Should -Match ([regex]::Escape($_.id))
        }
    }
}

Describe 'No em dashes anywhere in the repository' {

    It 'contains no em dash in <_.FullName>' -ForEach $script:TextFiles {
        $content = Get-Content -Path $_.FullName -Raw
        if ($null -eq $content) {
            $content = ''
        }
        $content.Contains([string][char]0x2014) | Should -BeFalse
    }
}
