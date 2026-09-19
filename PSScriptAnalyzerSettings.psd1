# PSScriptAnalyzer settings for the repository. Used by ./build.ps1 -Task Analyze, by the VS Code PowerShell
# extension and by Invoke-Formatter. The custom rules live in tools/ScriptAnalyzerRules/McpAnalyzerRules.psm1;
# the Analyze task passes that path explicitly.
@{
    Severity            = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        # Sources are UTF-8 without BOM; Windows PowerShell 5.1 is out of scope.
        'PSUseBOMForUnicodeEncodedFile'
        # Join-Path with several positional segments is idiomatic; named parameters are still expected elsewhere.
        'PSAvoidUsingPositionalParameters'
    )
    Rules               = @{
        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentIndentation = @{
            Enable              = $true
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind                = 'space'
        }
        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            # Hashtable values are aligned (PSAlignAssignmentStatement); CheckOperator must not flag the padding.
            IgnoreAssignmentOperatorInsideHashTable = $true
        }
        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }
        PSUseCorrectCasing         = @{
            Enable = $true
        }
        PSAvoidUsingCmdletAliases  = @{
            # The Invoke-Build DSL (task, assert, ...) and the Invoke-Build entry point are aliases by design.
            allowlist = @('task', 'assert', 'equals', 'exec', 'remove', 'property', 'requires', 'use', 'job', 'Invoke-Build')
        }
        PSProvideCommentHelp       = @{
            Enable                  = $true
            ExportedOnly            = $true
            BlockComment            = $true
            VSCodeSnippetCorrection = $false
            Placement               = 'begin'
        }
    }
}
