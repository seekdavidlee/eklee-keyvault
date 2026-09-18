#Requires -Modules Pester

. (Join-Path $PSScriptRoot '..\Start-Azd-Migration.ps1')

Describe 'ConvertTo-CustomDomainName' -Tag 'Unit' {
    It 'normalizes a fully qualified hostname' {
        ConvertTo-CustomDomainName -Value ' App.Example.COM. ' | Should Be 'app.example.com'
    }

    It 'returns null for a blank value' {
        ConvertTo-CustomDomainName -Value '   ' | Should BeNullOrEmpty
    }

    It 'rejects invalid hostnames' {
        $invalidHostnames = @(
            'https://app.example.com'
            'app.example.com:443'
            '192.0.2.10'
            'app..example.com'
            'app.example.com..'
            '-app.example.com'
            'app-.example.com'
            (('a' * 64) + '.example.com')
            ((('a' * 63) + '.') * 4 + 'com')
        )

        foreach ($invalidHostname in $invalidHostnames) {
            $threw = $false
            try {
                ConvertTo-CustomDomainName -Value $invalidHostname | Out-Null
            }
            catch {
                $threw = $true
            }

            $threw | Should Be $true
        }
    }
}

Describe 'Set-AzdEnvironment' -Tag 'Unit' {
    BeforeEach {
        Mock Test-Path { $false }
        Mock Invoke-ExternalCommand {}
    }

    It 'does not set the custom domain for a target without the property' {
        $target = [pscustomobject]@{
            tenantId = '00000000-0000-0000-0000-000000000001'
            subscriptionId = '00000000-0000-0000-0000-000000000002'
            environmentName = 'test'
            location = 'centralus'
            prefix = 'test'
            resourceGroupName = 'test-rg'
            enablePrivateNetworking = $false
            enableMiseSidecar = $false
            appRegistrationName = 'test-app'
        }

        Set-AzdEnvironment -Target $target -RepositoryPath $TestDrive

        Assert-MockCalled Invoke-ExternalCommand -ParameterFilter {
            $Arguments -contains 'CUSTOM_DOMAIN_NAME'
        } -Times 0 -Exactly
    }

    It 'does not set the custom domain for a blank property' {
        $target = [pscustomobject]@{
            tenantId = '00000000-0000-0000-0000-000000000001'
            subscriptionId = '00000000-0000-0000-0000-000000000002'
            environmentName = 'test'
            location = 'centralus'
            prefix = 'test'
            resourceGroupName = 'test-rg'
            customDomainName = ' '
            enablePrivateNetworking = $false
            enableMiseSidecar = $false
            appRegistrationName = 'test-app'
        }

        Set-AzdEnvironment -Target $target -RepositoryPath $TestDrive

        Assert-MockCalled Invoke-ExternalCommand -ParameterFilter {
            $Arguments -contains 'CUSTOM_DOMAIN_NAME'
        } -Times 0 -Exactly
    }

    It 'sets a normalized configured custom domain' {
        $target = [pscustomobject]@{
            tenantId = '00000000-0000-0000-0000-000000000001'
            subscriptionId = '00000000-0000-0000-0000-000000000002'
            environmentName = 'test'
            location = 'centralus'
            prefix = 'test'
            resourceGroupName = 'test-rg'
            customDomainName = 'App.Example.COM.'
            enablePrivateNetworking = $false
            enableMiseSidecar = $false
            appRegistrationName = 'test-app'
        }

        Set-AzdEnvironment -Target $target -RepositoryPath $TestDrive

        Assert-MockCalled Invoke-ExternalCommand -ParameterFilter {
            $Arguments -contains 'CUSTOM_DOMAIN_NAME' -and $Arguments -contains 'app.example.com'
        } -Times 1 -Exactly
    }
}