#Requires -Modules Pester
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT

$script:CustomDomainScriptPath = Join-Path $PSScriptRoot '..\..\Deployment\apply-custom-domain.ps1'

Describe 'apply-custom-domain.ps1' -Tag 'Unit' {
    It 'targets the root application container when updating custom-domain environment variables' {
        $scriptContent = Get-Content -LiteralPath $script:CustomDomainScriptPath -Raw

        $scriptContent | Should Match '\$applicationContainerName = "eklee-keyvault"'
        $scriptContent | Should Match '(?s)--container-name \$applicationContainerName `\s*--set-env-vars'
    }
}