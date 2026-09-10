function Invoke-GitHubCliApiMethod {
    [CmdletBinding()]
    param (
        [string]
        $Uri,

        [string]
        $Method,

        [string]
        $Body
    )
    
    if ($Method -eq "GET") {
        $response = gh api $Uri `
            --method $Method `
            --header "Accept: application/vnd.github+json" `
            --header "X-GitHub-Api-Version: 2022-11-28" `
            --paginate `
            --slurp
    }
    else {
        $response = $Body | gh api $Uri `
            --method $Method `
            --header "Accept: application/vnd.github+json" `
            --header "X-GitHub-Api-Version: 2022-11-28" `
            --input -
    }
    
    if ($?) {
        return ($response | ConvertFrom-Json)
    }
    else {
        throw ($response | ConvertFrom-Json)
    }
}

function Set-GitInfoIds {
    <#
        .SYNOPSIS
        Records the numeric GitHub owner and repository ids in a Bicep parameter file.

        .DESCRIPTION
        GitHub emits an immutable OIDC subject - repo:org@ownerId/repo@repoId:environment:... - for
        repositories created, renamed or transferred after 2026-07-15, with no way to opt out. An
        archetype can only build a federated credential matching it if the numeric ids reach it
        through the .bicepparam, so they are recorded in its 'param gitInfo' block as
        'organizationId' and 'repositoryId'.

        The ids are not a consumer preference. They have to match what GitHub puts in the token's
        subject claim, so an id already recorded is replaced rather than kept: a renamed or
        transferred repository, or a parameter file copied from another Landing Zone, would
        otherwise keep an id that authenticates as some other repository.

        .OUTPUTS
        'Recorded' when the file was rewritten, 'UpToDate' when both ids already matched, or
        'NoGitInfoBlock' when the file has nothing to record them in.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateScript({ $_ | Test-Path -PathType Leaf })]
        [string]
        $Path,

        [Parameter(Mandatory)]
        [string]
        $OrganizationId,

        [Parameter(Mandatory)]
        [string]
        $RepositoryId
    )

    $parameterContent = Get-Content -Raw -Path $Path -Encoding utf8

    #* 'gitInfo' is a consumer-owned parameter: a consumer may name it differently, or not have
    #* one. Nothing to write into is a no-op, not an error.
    $gitInfoBlock = [regex]::Match($parameterContent, "(?m)^param gitInfo\s*=\s*\{(?<body>.*?)\r?\n\}", "Singleline")
    if (!$gitInfoBlock.Success) {
        return "NoGitInfoBlock"
    }

    $gitInfo = $gitInfoBlock.Groups["body"].Value
    $updatedGitInfo = $gitInfo

    #* Match the line endings already in the file. Inserting "`n" into a CRLF file leaves it with
    #* mixed endings, and the anchors below would then not match on the next run.
    $eol = $parameterContent.Contains("`r`n") ? "`r`n" : "`n"

    foreach ($field in @(
            @{ Anchor = "organization"; Name = "organizationId"; Value = $OrganizationId }
            @{ Anchor = "repository"; Name = "repositoryId"; Value = $RepositoryId }
        )) {
        $line = "$($field.Name): '$($field.Value)'"

        #* An id already recorded is replaced, never preserved - see the description.
        $recorded = "(?m)^(?<indent>[ \t]*)$($field.Name)[ \t]*:[^\r\n]*"
        if ($updatedGitInfo -match $recorded) {
            $updatedGitInfo = [regex]::Replace($updatedGitInfo, $recorded, "`${indent}$line")
            continue
        }

        #* Anchored on the key rather than on a quoted value, because the value may be an
        #* expression and is replaced either way. [^\r\n]* rather than \s*: \s matches newlines
        #* too, so the match would run past the end of the line. The anchor cannot match the field
        #* it introduces - 'organization[ \t]*:' does not match 'organizationId:'.
        $anchor = "(?m)^(?<indent>[ \t]*)$($field.Anchor)[ \t]*:[^\r\n]*"
        if ($updatedGitInfo -match $anchor) {
            $updatedGitInfo = [regex]::Replace($updatedGitInfo, $anchor, "`${0}$eol`${indent}$line")
            continue
        }

        #* No key to sit next to. Position within the block is cosmetic, so append rather than
        #* record one id and drop the other: half a pair builds a subject that matches nothing,
        #* which is worse than the name-based one it replaces.
        $indent = [regex]::Match($updatedGitInfo, "(?m)^(?<indent>[ \t]+)\S").Groups["indent"].Value
        $indent = $indent ? $indent : "  "
        $updatedGitInfo = $updatedGitInfo.TrimEnd() + "$eol$indent$line"
    }

    if ($updatedGitInfo -eq $gitInfo) {
        return "UpToDate"
    }

    #* -NoNewline against -Raw round-trips the file exactly. Without it every run appends a
    #* newline, so a file that already ended with one grows a blank line each time.
    $updatedContent = $parameterContent.Remove($gitInfoBlock.Groups["body"].Index, $gitInfoBlock.Groups["body"].Length).Insert($gitInfoBlock.Groups["body"].Index, $updatedGitInfo)
    Set-Content -Path $Path -Value $updatedContent -Encoding utf8 -NoNewline

    return "Recorded"
}

function Join-HashTable {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [hashtable]
        $Hashtable1 = @{},
        
        [Parameter(Mandatory = $false)]
        [hashtable]
        $Hashtable2 = @{}
    )

    #* Null handling
    $Hashtable1 = $Hashtable1.Keys.Count -eq 0 ? @{} : $Hashtable1
    $Hashtable2 = $Hashtable2.Keys.Count -eq 0 ? @{} : $Hashtable2

    #* Needed for nested enumeration
    $hashtable1Clone = $Hashtable1.Clone()
    
    foreach ($key in $hashtable1Clone.Keys) {
        if ($key -in $hashtable2.Keys) {
            if ($hashtable1Clone[$key] -is [hashtable] -and $hashtable2[$key] -is [hashtable]) {
                $Hashtable2[$key] = Join-HashTable -Hashtable1 $hashtable1Clone[$key] -Hashtable2 $Hashtable2[$key]
            }
            elseif ($hashtable1Clone[$key] -is [array] -and $hashtable2[$key] -is [array]) {
                foreach ($item in $hashtable1Clone[$key]) {
                    if ($hashtable2[$key] -notcontains $item) {
                        $hashtable2[$key] += $item
                    }
                }
            }
        }
        else {
            $Hashtable2[$key] = $hashtable1Clone[$key]
        }
    }
    
    return $Hashtable2
}

function Join-Arrays {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [array]
        $Array1 = @(),
        
        [Parameter(Mandatory = $false)]
        [array]
        $Array2 = @()
    )

    foreach ($item in $Array1) {
        if ($Array2 -notcontains $item) {
            $Array2 += $item
        }
    }

    $Array2
}
