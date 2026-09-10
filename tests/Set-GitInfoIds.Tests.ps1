BeforeDiscovery {
    #* The compile test proves the rewritten file is still valid Bicep and that the ids reach the
    #* template. It needs the Bicep CLI, which is not part of the test runner image.
    $script:bicepAvailable = [bool](Get-Command -Name "bicep" -ErrorAction Ignore)
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/modules/support-functions.psm1" -Force

    $script:ownerId = "123456"
    $script:repositoryId = "7890123"

    #* Written through .NET rather than Set-Content so the fixture keeps exactly the bytes the test
    #* declares - line endings and a trailing newline included.
    function New-ParameterFile {
        param (
            [Parameter(Mandatory)]
            [string]
            $Content,

            [string]
            $Name = "prod.bicepparam"
        )

        $path = Join-Path -Path $TestDrive -ChildPath "$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $path = Join-Path -Path $path -ChildPath $Name
        [System.IO.File]::WriteAllText($path, $Content)
        return $path
    }

    function Get-FileText {
        param (
            [Parameter(Mandatory)]
            [string]
            $Path
        )

        return [System.IO.File]::ReadAllText($Path)
    }

    function Set-Ids {
        param (
            [Parameter(Mandatory)]
            [string]
            $Path,

            [string]
            $OrganizationId = $script:ownerId,

            [string]
            $RepositoryId = $script:repositoryId
        )

        return Set-GitInfoIds -Path $Path -OrganizationId $OrganizationId -RepositoryId $RepositoryId
    }
}

Describe "Set-GitInfoIds" {

    Context "Recording ids that are not there yet" {

        It "records both ids against their matching keys" {
            $path = New-ParameterFile -Content @"
using 'main.bicep'

param gitInfo = {
  organization: 'my-org'
  repository: 'my-repo'
  environment: 'prod'
}

"@
            Set-Ids -Path $path | Should -Be "Recorded"
            Get-FileText -Path $path | Should -BeExactly @"
using 'main.bicep'

param gitInfo = {
  organization: 'my-org'
  organizationId: '123456'
  repository: 'my-repo'
  repositoryId: '7890123'
  environment: 'prod'
}

"@
        }

        It "preserves CRLF line endings and does not mix them" {
            $path = New-ParameterFile -Content "param gitInfo = {`r`n  organization: 'my-org'`r`n  repository: 'my-repo'`r`n}`r`n"

            Set-Ids -Path $path | Should -Be "Recorded"

            $result = Get-FileText -Path $path
            $result | Should -BeExactly "param gitInfo = {`r`n  organization: 'my-org'`r`n  organizationId: '123456'`r`n  repository: 'my-repo'`r`n  repositoryId: '7890123'`r`n}`r`n"
            #* Every newline in the file is part of a CRLF pair.
            ([regex]::Matches($result, "`n")).Count | Should -Be ([regex]::Matches($result, "`r`n")).Count
        }

        It "preserves tab indentation" {
            $path = New-ParameterFile -Content "param gitInfo = {`n`torganization: 'my-org'`n`trepository: 'my-repo'`n}`n"

            Set-Ids -Path $path | Should -Be "Recorded"
            Get-FileText -Path $path | Should -BeExactly "param gitInfo = {`n`torganization: 'my-org'`n`torganizationId: '123456'`n`trepository: 'my-repo'`n`trepositoryId: '7890123'`n}`n"
        }

        It "does not add a trailing newline to a file that has none" {
            $path = New-ParameterFile -Content "param gitInfo = {`n  organization: 'my-org'`n  repository: 'my-repo'`n}"

            Set-Ids -Path $path | Should -Be "Recorded"
            Get-FileText -Path $path | Should -Not -Match "\n$"
        }

        It "leaves everything outside the gitInfo block untouched" {
            $path = New-ParameterFile -Content @"
using '../../archetypes/std/main.bicep'

param other = {
  organization: 'not-this-one'
  repository: 'not-this-one-either'
}

param gitInfo = {
  organization: 'my-org'
  repository: 'my-repo'
}

param trailing = 'value'

"@
            Set-Ids -Path $path | Should -Be "Recorded"

            $result = Get-FileText -Path $path
            $result | Should -BeLike "*param other = {`n  organization: 'not-this-one'`n  repository: 'not-this-one-either'`n}*"
            $result | Should -BeLike "*param trailing = 'value'*"
            #* Only the gitInfo block gained lines.
            ([regex]::Matches($result, "organizationId")).Count | Should -Be 1
            ([regex]::Matches($result, "repositoryId")).Count | Should -Be 1
        }
    }

    Context "Reconciling ids that are already there" {

        It "replaces ids carried over from another Landing Zone" {
            $path = New-ParameterFile -Content @"
param gitInfo = {
  organization: 'my-org'
  organizationId: '999'
  repository: 'my-repo'
  repositoryId: '888'
}

"@
            Set-Ids -Path $path | Should -Be "Recorded"

            $result = Get-FileText -Path $path
            $result | Should -BeLike "*organizationId: '123456'*"
            $result | Should -BeLike "*repositoryId: '7890123'*"
            $result | Should -Not -BeLike "*999*"
            $result | Should -Not -BeLike "*888*"
        }

        It "replaces an id that is an expression rather than a literal" {
            $path = New-ParameterFile -Content "param gitInfo = {`n  organization: 'my-org'`n  organizationId: readEnvironmentVariable('OWNER_ID')`n  repository: 'my-repo'`n}`n"

            Set-Ids -Path $path | Should -Be "Recorded"

            $result = Get-FileText -Path $path
            $result | Should -BeLike "*organizationId: '123456'*"
            $result | Should -Not -BeLike "*readEnvironmentVariable*"
        }

        It "reports UpToDate and leaves the file byte for byte when both ids already match" {
            $content = "param gitInfo = {`n  organization: 'my-org'`n  organizationId: '123456'`n  repository: 'my-repo'`n  repositoryId: '7890123'`n}`n"
            $path = New-ParameterFile -Content $content

            Set-Ids -Path $path | Should -Be "UpToDate"
            Get-FileText -Path $path | Should -BeExactly $content
        }

        It "is idempotent across repeated runs" {
            $path = New-ParameterFile -Content "param gitInfo = {`n  organization: 'my-org'`n  repository: 'my-repo'`n}`n"

            Set-Ids -Path $path | Should -Be "Recorded"
            $first = Get-FileText -Path $path

            Set-Ids -Path $path | Should -Be "UpToDate"
            Get-FileText -Path $path | Should -BeExactly $first
        }
    }

    Context "Finding somewhere to put the ids" {

        #* Both ids or neither: half a pair builds a subject that matches nothing, which is worse
        #* than the name-based subject it replaces.
        It "records both ids when <name>" -ForEach @(
            @{ Name = "the organization value is an expression"; Content = "param gitInfo = {`n  organization: orgVar`n  repository: 'my-repo'`n}`n" }
            @{ Name = "the anchor line carries a trailing comment"; Content = "param gitInfo = {`n  organization: 'my-org' // the org`n  repository: 'my-repo'`n}`n" }
            @{ Name = "only one of the two anchor keys is present"; Content = "param gitInfo = {`n  repository: 'my-repo'`n}`n" }
            @{ Name = "neither anchor key is present"; Content = "param gitInfo = {`n  environment: 'prod'`n}`n" }
            @{ Name = "the block holds nothing but the anchors"; Content = "param gitInfo = {`n  organization: 'my-org'`n  repository: 'my-repo'`n}`n" }
        ) {
            $path = New-ParameterFile -Content $Content

            Set-Ids -Path $path | Should -Be "Recorded"

            $result = Get-FileText -Path $path
            $result | Should -Match "(?m)^[ \t]*organizationId: '123456'$"
            $result | Should -Match "(?m)^[ \t]*repositoryId: '7890123'$"
        }
    }

    Context "Files it must not touch" {

        It "reports NoGitInfoBlock and leaves a file with no gitInfo block byte for byte" {
            $content = @"
using 'main.bicep'

param settings = {
  organization: 'my-org'
  repository: 'my-repo'
}

"@
            $path = New-ParameterFile -Content $content

            Set-Ids -Path $path | Should -Be "NoGitInfoBlock"
            Get-FileText -Path $path | Should -BeExactly $content
        }
    }

    Context "Bicep" -Skip:(-not $bicepAvailable) {

        It "produces a parameter file that compiles and carries the ids into the template" {
            $directory = Join-Path -Path $TestDrive -ChildPath "compile"
            New-Item -ItemType Directory -Path $directory -Force | Out-Null

            [System.IO.File]::WriteAllText((Join-Path -Path $directory -ChildPath "main.bicep"), @"
targetScope = 'subscription'

type gitInfoType = {
  organization: string
  organizationId: string
  repository: string
  repositoryId: string
  environment: string
}

param gitInfo gitInfoType

output subject string = 'repo:`${gitInfo.organization}@`${gitInfo.organizationId}/`${gitInfo.repository}@`${gitInfo.repositoryId}:environment:`${gitInfo.environment}'
"@)

            $path = Join-Path -Path $directory -ChildPath "prod.bicepparam"
            [System.IO.File]::WriteAllText($path, @"
using 'main.bicep'

param gitInfo = {
  organization: 'my-org'
  repository: 'my-repo'
  environment: 'prod'
}
"@)

            Set-Ids -Path $path | Should -Be "Recorded"

            $compiled = bicep build-params $path --stdout 2>&1
            $LASTEXITCODE | Should -Be 0 -Because "the rewritten parameter file must still be valid Bicep. Compiler output: $compiled"

            $parameters = ($compiled | ConvertFrom-Json).parametersJson | ConvertFrom-Json
            $parameters.parameters.gitInfo.value.organizationId | Should -Be "123456"
            $parameters.parameters.gitInfo.value.repositoryId | Should -Be "7890123"
        }
    }
}
