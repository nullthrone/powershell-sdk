BeforeDiscovery {
    $manifest = Get-Content -Path (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:specFiles = @($manifest['files'] | ForEach-Object {
            @{
                Path            = $_['path']
                Revision        = $_['revision']
                Sha256          = $_['sha256']
                DefinitionCount = $_['definitions']
                IsJson          = $_['path'].EndsWith('.json')
            }
        })
    $script:jsonRevisions = @($manifest['files'] | Where-Object { $_['path'].EndsWith('.json') } | ForEach-Object { $_['revision'] })
    $script:primaryRevision = $manifest['primaryRevision']
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Support' 'McpTestSupport.psm1') -Force
    $script:specDirectory = $PSScriptRoot
    $script:manifest = Get-Content -Path (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
    $script:primaryRevision = $script:manifest.primaryRevision
}

Describe 'Vendored specification schemas' -Tag 'Spec' {
    Context 'provenance' {
        It 'records the upstream repository and a full commit SHA' {
            $script:manifest.source | Should -Be 'https://github.com/modelcontextprotocol/modelcontextprotocol'
            $script:manifest.commit | Should -Match '^[0-9a-f]{40}$'
            $script:manifest.retrieved | Should -Match '^\d{4}-\d{2}-\d{2}$'
        }

        It 'covers the three supported revisions with schema.json and schema.ts' {
            $jsonRevisions = @($script:manifest.files | Where-Object { $_.path.EndsWith('.json') } | ForEach-Object { $_.revision } | Sort-Object)
            $tsRevisions = @($script:manifest.files | Where-Object { $_.path.EndsWith('.ts') } | ForEach-Object { $_.revision } | Sort-Object)
            $jsonRevisions | Should -Be @('2025-06-18', '2025-11-25', '2026-07-28')
            $tsRevisions | Should -Be $jsonRevisions
        }
    }

    Context '<Path>' -ForEach $script:specFiles {
        BeforeAll {
            $script:file = Join-Path $script:specDirectory $Path
        }

        It 'exists' {
            $script:file | Should -Exist
        }

        It 'has the recorded SHA-256 hash' {
            (Get-FileHash -Path $script:file -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $Sha256.ToLowerInvariant()
        }

        It 'parses as JSON with <DefinitionCount> definitions' -Skip:(-not $IsJson) {
            $definitions = Get-McpSpecDefinition -Revision $Revision
            $definitions.Count | Should -Be $DefinitionCount
        }
    }

    Context 'content' {
        It 'uses JSON Schema 2020-12 for <_>' -ForEach @('2026-07-28', '2025-11-25') {
            (Get-McpSpecSchema -Revision $_)['$schema'] | Should -Be 'https://json-schema.org/draft/2020-12/schema'
        }

        It 'uses JSON Schema draft-07 for 2025-06-18' {
            (Get-McpSpecSchema -Revision '2025-06-18')['$schema'] | Should -Be 'http://json-schema.org/draft-07/schema#'
        }

        It 'defines the JSON-RPC envelope with jsonrpc "2.0" in <_>' -ForEach $script:jsonRevisions {
            $definitions = Get-McpSpecDefinition -Revision $_
            foreach ($name in 'JSONRPCRequest', 'JSONRPCNotification', 'JSONRPCResponse') {
                $definitions.ContainsKey($name) | Should -BeTrue -Because "$name must exist in $_"
            }
            # The error envelope is JSONRPCError up to 2025-06-18 and JSONRPCErrorResponse from 2025-11-25.
            @('JSONRPCError', 'JSONRPCErrorResponse' | Where-Object { $definitions.ContainsKey($_) }).Count | Should -BeGreaterOrEqual 1
            # JSONRPCResponse is a union from 2025-11-25 on; the request and notification objects carry the constant.
            foreach ($name in 'JSONRPCRequest', 'JSONRPCNotification') {
                $definitions[$name]['properties']['jsonrpc']['const'] | Should -Be '2.0'
            }
        }

        It 'declares <_> as LATEST_PROTOCOL_VERSION in its schema.ts' -ForEach $script:jsonRevisions {
            $content = Get-Content -Path (Join-Path $script:specDirectory "${_}_schema.ts") -Raw
            $content | Should -Match ('LATEST_PROTOCOL_VERSION\s*=\s*"{0}"' -f [regex]::Escape($_))
        }

        It 'lists every definition of the primary revision in definitions-checklist.txt, ordinally sorted' {
            $expected = @((Get-McpSpecDefinition -Revision $script:primaryRevision).Keys)
            [Array]::Sort($expected, [System.StringComparer]::Ordinal)
            $actual = @(Get-Content -Path (Join-Path $script:specDirectory 'definitions-checklist.txt') | Where-Object { $_ -ne '' })
            $actual | Should -Be $expected
        }
    }
}
