@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Internal functions that only write local output files (baseline export folders) are named
        # with Save-, Remove-, Set-, and New- verbs but are not meant to be run interactively with -WhatIf
        # support; the tenant-facing script (Import-CaPolicyPack.ps1) implements ShouldProcess directly.
        'PSUseShouldProcessForStateChangingFunctions'
        # Several internal functions return collections and are named for what they return (for example
        # Get-CaPackTemplates).
        'PSUseSingularNouns'
    )
}
