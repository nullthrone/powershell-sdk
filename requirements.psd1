# Build and test dependencies (never required at runtime; see DEPENDENCY_POLICY.md).
# Modules use NuGet version-range notation and are installed by ./build.ps1 -Bootstrap from the PowerShell
# Gallery, from api.nuget.org (packages with a NuGetId) or from tools/packages/*.nupkg (offline).
@{
    Modules = @{
        Pester                         = @{ Version = '[6.2.0,7.0)'; NuGetId = 'Pester' }
        PSScriptAnalyzer               = @{ Version = '[1.25.0,2.0)' }
        ModuleBuilder                  = @{ Version = '[3.1.0,4.0)' }
        InvokeBuild                    = @{ Version = '[5.12.0,6.0)'; NuGetId = 'Invoke-Build' }
        'Microsoft.PowerShell.PlatyPS' = @{ Version = '[1.0.0,2.0)'; Optional = $true }
    }
    Npm     = @{
        # The npm "latest" dist-tag (0.1.x) does not know revision 2026-07-28; the alpha channel does.
        '@modelcontextprotocol/conformance' = '0.2.0-alpha.11'
        '@modelcontextprotocol/inspector'   = 'latest'
    }
}
