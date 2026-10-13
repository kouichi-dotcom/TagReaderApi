#Requires -Version 5.1
<#
.SYNOPSIS
  staging-only: Writes__* / API_READ_ONLY gate tests for the 3 write APIs.
  Does not touch prod App Service / prod App Settings / prod SQL permissions.

.NOTES
  For each case, forbidden POSTs must return 403 and must not change DB snapshots.
  Allowed POSTs may reach the controller (non-403). Case "all true" runs existing suites.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net',
    [string]$ResourceGroup = 'rg-ohmiyakoki-tagapp-api',
    [string]$AppName = 'ohmiyakoki-tagapp-api',
    [string]$SqlServer = 'localhost\SQLEXPRESS',
    [string]$SqlDatabase = 'OOMIYADB',
    [string]$ProbeEpc = 'e2006304040e01440720cce0',
    [int]$ProbeReception = 404140,
    [switch]$SkipExistingSuites
)

$ErrorActionPreference = 'Stop'
$AllowedBaseUrl = 'https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net'
if ($BaseUrl.TrimEnd('/') -ne $AllowedBaseUrl) {
    throw "Refusing non-staging BaseUrl: $BaseUrl"
}
if ($AppName -match 'prod') {
    throw "Refusing prod AppName: $AppName"
}

$results = New-Object System.Collections.Generic.List[object]

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & az @AzArguments 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

function Add-Result([string]$Id, [string]$Verdict, [string]$Detail) {
    $results.Add([pscustomobject]@{ Id = $Id; Verdict = $Verdict; Detail = $Detail })
    $color = if ($Verdict -eq 'PASS') { 'Green' } elseif ($Verdict -eq 'FAIL') { 'Red' } else { 'Yellow' }
    Write-Host "[$Verdict] $Id - $Detail" -ForegroundColor $color
}

function Get-SqlConnection {
    $cs = "Server=$SqlServer;Database=$SqlDatabase;Trusted_Connection=True;TrustServerCertificate=True;"
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    $conn.Open()
    return $conn
}

function Get-LedgerTableName {
    # ASCII-only source: IC + タグ台帳 (avoid PS 5.1 encoding issues)
    return ('IC' + [string]([char]0x30BF) + [string]([char]0x30B0) + [string]([char]0x53F0) + [string]([char]0x5E33))
}

function Get-DbSnapshot {
    $ledger = Get-LedgerTableName
    $conn = Get-SqlConnection
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @"
SELECT
  (SELECT COUNT(1) FROM [dbo].[tag_table3]) AS t3,
  (SELECT COUNT(1) FROM [dbo].[$ledger]) AS ledger,
  (SELECT CONVERT(varchar(30), [updated], 121) FROM [dbo].[$ledger] WHERE LTRIM(RTRIM([tag_id2]))=@epc) AS epcUpdated,
  (SELECT LTRIM(RTRIM([tag_mode2])) FROM [dbo].[$ledger] WHERE LTRIM(RTRIM([tag_id2]))=@epc) AS epcMode
"@
        $null = $cmd.Parameters.AddWithValue('@epc', $ProbeEpc)
        $r = $cmd.ExecuteReader()
        $r.Read() | Out-Null
        $snap = [pscustomobject]@{
            T3 = [int]$r['t3']
            Ledger = [int]$r['ledger']
            EpcUpdated = [string]$r['epcUpdated']
            EpcMode = [string]$r['epcMode']
        }
        $r.Close()
        return $snap
    }
    finally { $conn.Close() }
}

function Invoke-JsonPost([string]$Url, [string]$Body) {
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method POST -Body $Body -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 60
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $resp.Content }
    }
    catch {
        $code = $null
        $body = ''
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
            } catch {}
        }
        if (-not $body -and $_.ErrorDetails.Message) { $body = $_.ErrorDetails.Message }
        return [pscustomobject]@{ Status = $code; Body = $body }
    }
}

function Wait-StagingHealthy {
    $url = "$BaseUrl/api/environment"
    for ($i = 1; $i -le 18; $i++) {
        try {
            $env = Invoke-RestMethod -Uri $url -TimeoutSec 30
            if ($env.databaseKind -eq 'Local' -and $env.readOnly -eq $false) {
                Write-Host "Healthy: environment=$($env.environment) databaseKind=$($env.databaseKind) readOnly=$($env.readOnly)"
                return $env
            }
            Write-Host "Unexpected environment response (attempt $i): $($env | ConvertTo-Json -Compress)"
        }
        catch {
            Write-Host "Health attempt $i failed: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 8
    }
    throw "Staging health check failed: $url"
}

function Wait-WriteGateReady {
    param(
        [string]$ApiReadOnly,
        [string]$ProductUpdates,
        [string]$TagLedger,
        [string]$LinkTags
    )
    # Confirm middleware sees new settings (avoid testing against a stale instance).
    $expectGlobal403 = ($ApiReadOnly -eq 'true')
    $expectPu403 = $expectGlobal403 -or ($ProductUpdates -ne 'true')
    $expectTl403 = $expectGlobal403 -or ($TagLedger -ne 'true')
    $expectLt403 = $expectGlobal403 -or ($LinkTags -ne 'true')

    for ($i = 1; $i -le 24; $i++) {
        $pu = Invoke-JsonPost -Url "$BaseUrl/api/product-updates" -Body '{}'
        $tl = Invoke-JsonPost -Url "$BaseUrl/api/products/tag-ledger" -Body '{}'
        $lt = Invoke-JsonPost -Url "$BaseUrl/api/reception-slips/$ProbeReception/link-tags" -Body '{}'

        $puOk = if ($expectPu403) { $pu.Status -eq 403 } else { ($null -ne $pu.Status) -and ($pu.Status -ne 403) }
        $tlOk = if ($expectTl403) { $tl.Status -eq 403 } else { ($null -ne $tl.Status) -and ($tl.Status -ne 403) }
        $ltOk = if ($expectLt403) { $lt.Status -eq 403 } else { ($null -ne $lt.Status) -and ($lt.Status -ne 403) }

        if ($expectGlobal403) {
            $msgOk = ($pu.Body -match 'read-only') -and ($tl.Body -match 'read-only') -and ($lt.Body -match 'read-only')
        }
        else {
            # Must have left global API_READ_ONLY mode.
            $stillGlobal = ($pu.Body -match 'read-only') -or ($tl.Body -match 'read-only') -or ($lt.Body -match 'read-only')
            $msgOk = -not $stillGlobal
        }

        if ($puOk -and $tlOk -and $ltOk -and $msgOk) {
            Write-Host "Write-gate ready (attempt $i): PU=$($pu.Status) TL=$($tl.Status) LT=$($lt.Status)"
            return
        }
        Write-Host "Write-gate not ready (attempt $i): PU=$($pu.Status)/$($pu.Body) TL=$($tl.Status) LT=$($lt.Status)"
        Start-Sleep -Seconds 8
    }
    throw "Write-gate settings not observed after restart"
}

function Set-StagingWriteSettings {
    param(
        [string]$ApiReadOnly,
        [string]$ProductUpdates,
        [string]$TagLedger,
        [string]$LinkTags
    )
    Write-Host "Set App Settings: API_READ_ONLY=$ApiReadOnly Writes__ProductUpdates=$ProductUpdates Writes__TagLedger=$TagLedger Writes__LinkTags=$LinkTags" -ForegroundColor Cyan
    $set = Invoke-Az -AzArguments @(
        'webapp','config','appsettings','set',
        '--resource-group', $ResourceGroup,
        '--name', $AppName,
        '--settings',
        "API_READ_ONLY=$ApiReadOnly",
        "Writes__ProductUpdates=$ProductUpdates",
        "Writes__TagLedger=$TagLedger",
        "Writes__LinkTags=$LinkTags",
        '--output','none'
    )
    if ($set.ExitCode -ne 0) { throw "az webapp config appsettings set failed: $($set.ExitCode)" }
    $restart = Invoke-Az -AzArguments @('webapp','restart','--resource-group',$ResourceGroup,'--name',$AppName,'--output','none')
    if ($restart.ExitCode -ne 0) { throw "az webapp restart failed: $($restart.ExitCode)" }
    Start-Sleep -Seconds 15
    Wait-StagingHealthy | Out-Null
    Wait-WriteGateReady -ApiReadOnly $ApiReadOnly -ProductUpdates $ProductUpdates -TagLedger $TagLedger -LinkTags $LinkTags
}

function Test-ThreePosts {
    param(
        [string]$CaseId,
        [bool]$ExpectProductUpdatesAllowed,
        [bool]$ExpectTagLedgerAllowed,
        [bool]$ExpectLinkTagsAllowed,
        [ValidateSet('global','writes')]
        [string]$ForbiddenReason = 'writes'
    )

    $before = Get-DbSnapshot
    $pu = Invoke-JsonPost -Url "$BaseUrl/api/product-updates" -Body '{}'
    $tl = Invoke-JsonPost -Url "$BaseUrl/api/products/tag-ledger" -Body '{}'
    $lt = Invoke-JsonPost -Url "$BaseUrl/api/reception-slips/$ProbeReception/link-tags" -Body '{}'
    $after = Get-DbSnapshot

    $dbUnchanged = ($before.T3 -eq $after.T3) -and ($before.Ledger -eq $after.Ledger) `
        -and ($before.EpcUpdated -eq $after.EpcUpdated) -and ($before.EpcMode -eq $after.EpcMode)

    function Assert-One([string]$Name, $Resp, [bool]$Allowed) {
        if ($Allowed) {
            if ($Resp.Status -eq 403) {
                Add-Result -Id "$CaseId-$Name" -Verdict 'FAIL' -Detail "expected non-403 (controller reach) got 403 body=$($Resp.Body)"
            }
            else {
                Add-Result -Id "$CaseId-$Name" -Verdict 'PASS' -Detail "allowed Status=$($Resp.Status) (not 403)"
            }
        }
        else {
            $msgOk = if ($ForbiddenReason -eq 'global') {
                $Resp.Body -match 'read-only'
            } else {
                ($Resp.Body -match 'disabled') -and ($Resp.Body -notmatch 'read-only')
            }
            if ($Resp.Status -eq 403 -and $msgOk) {
                Add-Result -Id "$CaseId-$Name" -Verdict 'PASS' -Detail "403 body=$($Resp.Body)"
            }
            else {
                Add-Result -Id "$CaseId-$Name" -Verdict 'FAIL' -Detail "expected 403($ForbiddenReason) got Status=$($Resp.Status) body=$($Resp.Body)"
            }
        }
    }

    Assert-One 'product-updates' $pu $ExpectProductUpdatesAllowed
    Assert-One 'tag-ledger' $tl $ExpectTagLedgerAllowed
    Assert-One 'link-tags' $lt $ExpectLinkTagsAllowed

    if ($dbUnchanged) {
        Add-Result -Id "$CaseId-DB" -Verdict 'PASS' -Detail "DB unchanged t3=$($after.T3) ledger=$($after.Ledger) epcUpdated=$($after.EpcUpdated)"
    }
    else {
        Add-Result -Id "$CaseId-DB" -Verdict 'FAIL' -Detail "DB changed before=$($before | ConvertTo-Json -Compress) after=$($after | ConvertTo-Json -Compress)"
    }
}

Write-Host "=== staging write-gate tests ===" -ForegroundColor Cyan
Write-Host "App=$AppName BaseUrl=$BaseUrl"

# Capture current settings to restore later
$list = Invoke-Az -AzArguments @('webapp','config','appsettings','list','--resource-group',$ResourceGroup,'--name',$AppName,'-o','json')
if ($list.ExitCode -ne 0 -or -not $list.Output) {
    throw "Failed to list staging app settings"
}
$beforeSettings = $list.Output | ConvertFrom-Json
function Get-SettingValue([string]$Name) {
    $s = $beforeSettings | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($null -eq $s) { return $null }
    return [string]$s.value
}
$orig = @{
    API_READ_ONLY = Get-SettingValue 'API_READ_ONLY'
    ProductUpdates = Get-SettingValue 'Writes__ProductUpdates'
    TagLedger = Get-SettingValue 'Writes__TagLedger'
    LinkTags = Get-SettingValue 'Writes__LinkTags'
}
Write-Host ("Original settings: " + ($orig | ConvertTo-Json -Compress))

try {
    # Case 1: API_READ_ONLY=true, all Writes=true => all 403
    Set-StagingWriteSettings -ApiReadOnly 'true' -ProductUpdates 'true' -TagLedger 'true' -LinkTags 'true'
    Test-ThreePosts -CaseId 'C1-globalRO' -ExpectProductUpdatesAllowed:$false -ExpectTagLedgerAllowed:$false -ExpectLinkTagsAllowed:$false -ForbiddenReason global

    # Case 2: API_READ_ONLY=false, all Writes=false => all 403
    Set-StagingWriteSettings -ApiReadOnly 'false' -ProductUpdates 'false' -TagLedger 'false' -LinkTags 'false'
    Test-ThreePosts -CaseId 'C2-allOff' -ExpectProductUpdatesAllowed:$false -ExpectTagLedgerAllowed:$false -ExpectLinkTagsAllowed:$false -ForbiddenReason writes

    # Case 3: only ProductUpdates
    Set-StagingWriteSettings -ApiReadOnly 'false' -ProductUpdates 'true' -TagLedger 'false' -LinkTags 'false'
    Test-ThreePosts -CaseId 'C3-PU' -ExpectProductUpdatesAllowed:$true -ExpectTagLedgerAllowed:$false -ExpectLinkTagsAllowed:$false -ForbiddenReason writes

    # Case 4: only TagLedger
    Set-StagingWriteSettings -ApiReadOnly 'false' -ProductUpdates 'false' -TagLedger 'true' -LinkTags 'false'
    Test-ThreePosts -CaseId 'C4-TL' -ExpectProductUpdatesAllowed:$false -ExpectTagLedgerAllowed:$true -ExpectLinkTagsAllowed:$false -ForbiddenReason writes

    # Case 5: only LinkTags
    Set-StagingWriteSettings -ApiReadOnly 'false' -ProductUpdates 'false' -TagLedger 'false' -LinkTags 'true'
    Test-ThreePosts -CaseId 'C5-LT' -ExpectProductUpdatesAllowed:$false -ExpectTagLedgerAllowed:$false -ExpectLinkTagsAllowed:$true -ForbiddenReason writes

    # Case 6: all writable (staging normal for existing suites)
    Set-StagingWriteSettings -ApiReadOnly 'false' -ProductUpdates 'true' -TagLedger 'true' -LinkTags 'true'
    Test-ThreePosts -CaseId 'C6-allOn' -ExpectProductUpdatesAllowed:$true -ExpectTagLedgerAllowed:$true -ExpectLinkTagsAllowed:$true -ForbiddenReason writes

    if (-not $SkipExistingSuites) {
        function Invoke-ExistingSuite([string]$Id, [string]$ScriptName, [switch]$WithSkipParallel) {
            Write-Host ""
            Write-Host "=== Existing suite: $Id ===" -ForegroundColor Yellow
            $scriptPath = Join-Path $PSScriptRoot $ScriptName
            if ($WithSkipParallel) {
                & $scriptPath -SkipParallel
            }
            else {
                & $scriptPath
            }
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                Add-Result -Id $Id -Verdict 'PASS' -Detail "exit=0"
            }
            else {
                Add-Result -Id $Id -Verdict 'FAIL' -Detail "exit=$code"
            }
        }

        Invoke-ExistingSuite -Id 'SUITE-PU' -ScriptName 'test-product-updates-staging.ps1'
        Invoke-ExistingSuite -Id 'SUITE-TL' -ScriptName 'test-tag-ledger-staging.ps1' -WithSkipParallel
        Invoke-ExistingSuite -Id 'SUITE-LT' -ScriptName 'test-link-tags-staging.ps1' -WithSkipParallel
    }
}
finally {
    # Leave staging writable for ongoing tests: API_READ_ONLY=false + all Writes=true
    # (do not restore "unset" which would fail-closed block writes)
    Write-Host "Restore staging to writable baseline (API_READ_ONLY=false, Writes all true)" -ForegroundColor Cyan
    try {
        Set-StagingWriteSettings -ApiReadOnly 'false' -ProductUpdates 'true' -TagLedger 'true' -LinkTags 'true'
    }
    catch {
        Write-Host "WARNING: failed to restore staging write settings: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$pass = @($results | Where-Object Verdict -eq 'PASS').Count
$fail = @($results | Where-Object Verdict -eq 'FAIL').Count
Write-Host ""
Write-Host "=== SUMMARY PASS=$pass FAIL=$fail ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
$results | Format-Table -AutoSize
$out = Join-Path $PSScriptRoot 'test-writes-gates-staging-last-result.json'
$results | ConvertTo-Json -Depth 4 | Set-Content -Path $out -Encoding UTF8
Write-Host "Wrote $out"
if ($fail -gt 0) { exit 1 }
