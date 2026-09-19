@{
    Modules = @{
        Pester                         = @{ Version = '[6.2.0,7.0)'; NuGetId = 'Pester' }
        PSScriptAnalyzer               = @{ Version = '[1.25.0,2.0)' }
        ModuleBuilder                  = @{ Version = '[3.1.0,4.0)' }
        # Transitive dependencies of ModuleBuilder (RequiredModules: ModuleBuilder -> Configuration -> Metadata).
        # They are declared here so that their version ranges are pinned and the bootstrap never relies on the
        # dependency resolution of the package source (Install-PSResource is called with -SkipDependencyCheck).
        Configuration                  = @{ Version = '[1.5.0,2.0)'; DependencyOf = 'ModuleBuilder' }
        Metadata                       = @{ Version = '[1.5.1,2.0)'; DependencyOf = 'Configuration' }
        InvokeBuild                    = @{ Version = '[5.12.0,6.0)'; NuGetId = 'Invoke-Build' }
        'Microsoft.PowerShell.PlatyPS' = @{ Version = '[1.0.0,2.0)'; Optional = $true }
    }
    Npm     = @{
        '@modelcontextprotocol/conformance' = '0.2.0-alpha.11'
        '@modelcontextprotocol/inspector'   = 'latest'
    }
}
