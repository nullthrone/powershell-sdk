# Suffix: ModuleBuilder appends this file after all source files.
#
# Classes and enums defined in a script module are not visible to callers by name unless they use
# `using module`. The module therefore registers its engine types as type accelerators on import and removes
# them again when the module is unloaded (Remove-Module). Registration is idempotent so that
# Import-Module -Force works; the accelerator then points at the newly compiled type.

$script:McpTypeAccelerators = @(
    @{ Name = 'McpEra'; Type = [McpEra] }
    @{ Name = 'McpLoggingLevel'; Type = [McpLoggingLevel] }
    @{ Name = 'McpProtocolException'; Type = [McpProtocolException] }
)

$script:McpTypeAcceleratorRegistry = [psobject].Assembly.GetType('System.Management.Automation.TypeAccelerators')

foreach ($accelerator in $script:McpTypeAccelerators) {
    if ($script:McpTypeAcceleratorRegistry::Get.ContainsKey($accelerator.Name)) {
        $null = $script:McpTypeAcceleratorRegistry::Remove($accelerator.Name)
    }
    $script:McpTypeAcceleratorRegistry::Add($accelerator.Name, $accelerator.Type)
}

$ExecutionContext.SessionState.Module.OnRemove = {
    foreach ($accelerator in $script:McpTypeAccelerators) {
        $null = $script:McpTypeAcceleratorRegistry::Remove($accelerator.Name)
    }
}
