#Requires -Version 5.1
<#
.SYNOPSIS
  POST /api/product-updates staging-only smoke/edge tests.
  Allowed change: this script only. Does not modify API/Flutter code or prod settings.
  Source is ASCII-only so Windows PowerShell 5.1 parses reliably.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net'
)

$ErrorActionPreference = 'Stop'
$AllowedBaseUrl = 'https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net'

if ($BaseUrl -ne $AllowedBaseUrl) {
    Write-Error "REFUSED: BaseUrl must exactly match staging URL.`n  given : '$BaseUrl'`n  allowed: '$AllowedBaseUrl'"
    exit 2
}

$results = New-Object System.Collections.Generic.List[object]
$fixedEpc = $null
$originalStatus = $null
$restored = $false

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Get-JsonProperty($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    $alt = $obj.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
    if ($alt) { return $alt.Value }
    return $null
}

function Invoke-ApiRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [string]$Body,
        [string]$ContentType = 'application/json; charset=utf-8',
        [int]$TimeoutSec = 60
    )
    $uri = "$BaseUrl$Path"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Method -eq 'GET') {
            $resp = Invoke-WebRequest -Uri $uri -Method GET -TimeoutSec $TimeoutSec -UseBasicParsing
        }
        elseif ($null -eq $Body) {
            $resp = Invoke-WebRequest -Uri $uri -Method POST -TimeoutSec $TimeoutSec -UseBasicParsing `
                -ContentType $ContentType
        }
        else {
            $resp = Invoke-WebRequest -Uri $uri -Method POST -TimeoutSec $TimeoutSec -UseBasicParsing `
                -ContentType $ContentType -Body ([System.Text.Encoding]::UTF8.GetBytes($Body))
        }
        $sw.Stop()
        $parsed = $null
        if ($resp.Content) {
            try { $parsed = $resp.Content | ConvertFrom-Json } catch { $parsed = $resp.Content }
        }
        return [pscustomobject]@{
            Ok           = $true
            StatusCode   = [int]$resp.StatusCode
            Body         = $parsed
            Raw          = $resp.Content
            Error        = $null
            ElapsedMs    = $sw.ElapsedMilliseconds
            ClientFailed = $false
        }
    }
    catch {
        $sw.Stop()
        $ex = $_.Exception
        $statusCode = $null
        $raw = $null
        $parsed = $null
        if ($ex.Response) {
            try { $statusCode = [int]$ex.Response.StatusCode } catch { }
            try {
                $stream = $ex.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $raw = $reader.ReadToEnd()
                    $reader.Close()
                    try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $raw }
                }
            }
            catch { }
        }
        if (-not $statusCode -and $_.ErrorDetails -and $_.ErrorDetails.Message) {
            $raw = $_.ErrorDetails.Message
            try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $raw }
        }
        if (-not $statusCode -and $ex.Message -match ',\s*\((\d{3})\)') {
            $statusCode = [int]$Matches[1]
        }
        # PS 5.1 often wraps HTTP errors; dig for StatusCode
        if (-not $statusCode) {
            $respProp = $_.Exception.PSObject.Properties['Response']
            if ($respProp -and $respProp.Value) {
                try { $statusCode = [int]$respProp.Value.StatusCode } catch { }
            }
        }
        if (-not $statusCode -and $_.Exception.InnerException) {
            $inner = $_.Exception.InnerException
            if ($inner.Response) {
                try { $statusCode = [int]$inner.Response.StatusCode } catch { }
            }
        }
        $clientFailed = -not $statusCode
        return [pscustomobject]@{
            Ok           = $false
            StatusCode   = $statusCode
            Body         = $parsed
            Raw          = $raw
            Error        = $ex.Message
            ElapsedMs    = $sw.ElapsedMilliseconds
            ClientFailed = $clientFailed
        }
    }
}

function Get-ProductByEpc([string]$Epc) {
    return Invoke-ApiRequest -Method GET -Path ("/api/products?epc=" + [uri]::EscapeDataString($Epc))
}

function Post-ProductUpdate([string]$JsonBody, [int]$TimeoutSec = 60) {
    return Invoke-ApiRequest -Method POST -Path '/api/product-updates' -Body $JsonBody -TimeoutSec $TimeoutSec
}

function New-UpdateBody {
    param(
        [string]$Epc,
        [string]$Status,
        [string]$UserId = $null
    )
    $obj = [ordered]@{
        epc     = $Epc
        read_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        changes = @{ status = $Status }
    }
    if ($UserId) { $obj['user_id'] = $UserId }
    return ($obj | ConvertTo-Json -Compress -Depth 5)
}

function Add-Result {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Verdict,
        [string]$Expected,
        [string]$Actual,
        [string]$Notes = ''
    )
    $row = [pscustomobject]@{
        Id       = $Id
        Name     = $Name
        Verdict  = $Verdict
        Expected = $Expected
        Actual   = $Actual
        Notes    = $Notes
    }
    $results.Add($row) | Out-Null
    $color = switch ($Verdict) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        default { 'Yellow' }
    }
    Write-Host ("[{0}] {1} {2} - {3}" -f $Verdict, $Id, $Name, $Actual) -ForegroundColor $color
    if ($Notes) { Write-Host "         $Notes" -ForegroundColor DarkGray }
}

function Assert-StatusCode {
    param(
        [string]$Id,
        [string]$Name,
        $Response,
        [int[]]$ExpectedCodes,
        [string]$Notes = ''
    )
    $actual = if ($null -eq $Response.StatusCode) {
        "client-fail: $($Response.Error)"
    } else {
        "$($Response.StatusCode) body=$($Response.Raw)"
    }
    $code = $Response.StatusCode
    if ($null -ne $code -and ($ExpectedCodes -contains [int]$code)) {
        Add-Result -Id $Id -Name $Name -Verdict 'PASS' `
            -Expected ("HTTP " + ($ExpectedCodes -join '|')) -Actual $actual -Notes $Notes
        return $true
    }
    Add-Result -Id $Id -Name $Name -Verdict 'FAIL' `
        -Expected ("HTTP " + ($ExpectedCodes -join '|')) -Actual $actual -Notes $Notes
    return $false
}

function Restore-OriginalStatus {
    if (-not $fixedEpc) { return }
    if ($null -eq $originalStatus) {
        Write-Host "WARN: original status unknown; skip restore" -ForegroundColor Yellow
        return
    }
    if ([string]::IsNullOrWhiteSpace($originalStatus)) {
        Write-Host "WARN: original status blank; cannot POST blank status (400). Leaving current value." -ForegroundColor Yellow
        $script:restored = $false
        return
    }
    Write-Section "RESTORE original status"
    $body = New-UpdateBody -Epc $fixedEpc -Status $originalStatus -UserId '1'
    $r = Post-ProductUpdate -JsonBody $body
    $after = Get-ProductByEpc -Epc $fixedEpc
    $statusNow = Get-JsonProperty $after.Body 'status'
    if ($r.StatusCode -eq 200 -and $statusNow -eq $originalStatus) {
        Write-Host "Restored OK: epc=$fixedEpc status='$originalStatus'" -ForegroundColor Green
        $script:restored = $true
    }
    else {
        Write-Host "RESTORE FAILED: HTTP=$($r.StatusCode) statusNow='$statusNow' expected='$originalStatus' err=$($r.Error)" -ForegroundColor Red
        $script:restored = $false
    }
}

try {
    Write-Section "GATE: BaseUrl exact match"
    Write-Host "BaseUrl=$BaseUrl"

    Write-Section "GATE: GET /api/environment"
    $envResp = Invoke-ApiRequest -Method GET -Path '/api/environment'
    if ($envResp.StatusCode -ne 200) {
        Write-Error "REFUSED: /api/environment failed: $($envResp.Error) $($envResp.Raw)"
        exit 2
    }
    $envObj = $envResp.Body
    $readOnly = Get-JsonProperty $envObj 'readOnly'
    $databaseKind = Get-JsonProperty $envObj 'databaseKind'
    $environment = Get-JsonProperty $envObj 'environment'
    Write-Host ("environment={0} databaseKind={1} readOnly={2}" -f $environment, $databaseKind, $readOnly)

    if ($readOnly -ne $false) {
        Write-Error "REFUSED: readOnly must be false. got=$readOnly"
        exit 2
    }
    if ("$databaseKind" -eq 'Production') {
        Write-Error "REFUSED: databaseKind must not be Production. got=$databaseKind"
        exit 2
    }
    Write-Host "Gate PASSED" -ForegroundColor Green

    Write-Section "FIX EPC (single)"
    $rand = Invoke-ApiRequest -Method GET -Path '/api/products/random?count=1'
    if ($rand.StatusCode -ne 200) {
        Write-Error "Failed to get random product: $($rand.Error) $($rand.Raw)"
        exit 1
    }
    $item = $null
    if ($rand.Body -is [System.Array]) { $item = $rand.Body[0] }
    elseif ($rand.Body) { $item = @($rand.Body)[0] }
    $fixedEpc = Get-JsonProperty $item 'tagId2'
    if (-not $fixedEpc) { $fixedEpc = Get-JsonProperty $item 'TagId2' }
    if (-not $fixedEpc) {
        Write-Error "Could not extract tagId2 from random response: $($rand.Raw)"
        exit 1
    }

    $before = Get-ProductByEpc -Epc $fixedEpc
    if ($before.StatusCode -ne 200) {
        Write-Error "GET product before failed for epc=$fixedEpc : $($before.Raw)"
        exit 1
    }
    $originalStatus = Get-JsonProperty $before.Body 'status'
    Write-Host "Fixed EPC=$fixedEpc"
    Write-Host "Original status='$originalStatus'"
    Write-Host ("Product: code={0} name={1}" -f (Get-JsonProperty $before.Body 'productCode'), (Get-JsonProperty $before.Body 'productName'))

    # -------- N1 --------
    Write-Section "N1 normal update"
    $statusN1 = 'STAGING_TEST_N1'
    $rN1 = Post-ProductUpdate -JsonBody (New-UpdateBody -Epc $fixedEpc -Status $statusN1)
    $gN1 = Get-ProductByEpc -Epc $fixedEpc
    $stN1 = Get-JsonProperty $gN1.Body 'status'
    $n1Ok = ($rN1.StatusCode -eq 200) -and ((Get-JsonProperty $rN1.Body 'updated') -eq 1) `
        -and ((Get-JsonProperty $rN1.Body 'logRecorded') -eq $true) -and ($stN1 -eq $statusN1)
    if ($n1Ok) {
        Add-Result -Id 'N1' -Name 'normal update' -Verdict 'PASS' `
            -Expected "200 updated=1 logRecorded=true status=$statusN1" `
            -Actual "HTTP $($rN1.StatusCode) status=$stN1 body=$($rN1.Raw)"
    }
    else {
        Add-Result -Id 'N1' -Name 'normal update' -Verdict 'FAIL' `
            -Expected "200 updated=1 logRecorded=true status=$statusN1" `
            -Actual "HTTP $($rN1.StatusCode) GET status=$stN1 body=$($rN1.Raw) err=$($rN1.Error)"
    }

    # -------- N2 --------
    Write-Section "N2 with user_id"
    $statusN2 = 'STAGING_TEST_N2'
    $rN2 = Post-ProductUpdate -JsonBody (New-UpdateBody -Epc $fixedEpc -Status $statusN2 -UserId '1')
    $gN2 = Get-ProductByEpc -Epc $fixedEpc
    $stN2 = Get-JsonProperty $gN2.Body 'status'
    if ($rN2.StatusCode -eq 200 -and $stN2 -eq $statusN2) {
        Add-Result -Id 'N2' -Name 'with user_id' -Verdict 'PASS' `
            -Expected "200 status=$statusN2" -Actual "HTTP $($rN2.StatusCode) status=$stN2 body=$($rN2.Raw)"
    }
    else {
        Add-Result -Id 'N2' -Name 'with user_id' -Verdict 'FAIL' `
            -Expected "200 status=$statusN2" -Actual "HTTP $($rN2.StatusCode) status=$stN2 body=$($rN2.Raw) err=$($rN2.Error)"
    }

    # -------- E1 --------
    Write-Section "E1 nonexistent EPC"
    $fakeEpc = 'ffffffffffffffffffffffffffffffffdeadbeef'
    $rE1 = Post-ProductUpdate -JsonBody (New-UpdateBody -Epc $fakeEpc -Status 'OK')
    Assert-StatusCode -Id 'E1' -Name 'nonexistent EPC' -Response $rE1 -ExpectedCodes @(404) | Out-Null

    # -------- E2 --------
    Write-Section "E2 epc missing/empty/null"
    $e2a = Post-ProductUpdate -JsonBody '{"read_at":"2026-09-28T12:00:00","changes":{"status":"OK"}}'
    Assert-StatusCode -Id 'E2a' -Name 'epc missing' -Response $e2a -ExpectedCodes @(400) | Out-Null
    $e2b = Post-ProductUpdate -JsonBody '{"epc":"","read_at":"2026-09-28T12:00:00","changes":{"status":"OK"}}'
    Assert-StatusCode -Id 'E2b' -Name 'epc empty' -Response $e2b -ExpectedCodes @(400) | Out-Null
    $e2c = Post-ProductUpdate -JsonBody '{"epc":"   ","read_at":"2026-09-28T12:00:00","changes":{"status":"OK"}}'
    Assert-StatusCode -Id 'E2c' -Name 'epc whitespace' -Response $e2c -ExpectedCodes @(400) | Out-Null
    $e2d = Post-ProductUpdate -JsonBody '{"epc":null,"read_at":"2026-09-28T12:00:00","changes":{"status":"OK"}}'
    Assert-StatusCode -Id 'E2d' -Name 'epc null' -Response $e2d -ExpectedCodes @(400) | Out-Null

    # -------- E3 --------
    Write-Section "E3 status missing/empty/null"
    $e3a = Post-ProductUpdate -JsonBody ("{`"epc`":`"$fixedEpc`",`"read_at`":`"2026-09-28T12:00:00`"}")
    Assert-StatusCode -Id 'E3a' -Name 'changes missing' -Response $e3a -ExpectedCodes @(400) | Out-Null
    $e3b = Post-ProductUpdate -JsonBody ("{`"epc`":`"$fixedEpc`",`"read_at`":`"2026-09-28T12:00:00`",`"changes`":{`"status`":`"`"}}")
    Assert-StatusCode -Id 'E3b' -Name 'status empty' -Response $e3b -ExpectedCodes @(400) | Out-Null
    $e3c = Post-ProductUpdate -JsonBody ("{`"epc`":`"$fixedEpc`",`"read_at`":`"2026-09-28T12:00:00`",`"changes`":{`"status`":null}}")
    Assert-StatusCode -Id 'E3c' -Name 'status null' -Response $e3c -ExpectedCodes @(400) | Out-Null

    # -------- E4 --------
    Write-Section "E4 empty body / bad JSON"
    $e4a = Invoke-ApiRequest -Method POST -Path '/api/product-updates' -Body ''
    Assert-StatusCode -Id 'E4a' -Name 'empty body' -Response $e4a -ExpectedCodes @(400) | Out-Null
    $e4b = Invoke-ApiRequest -Method POST -Path '/api/product-updates' -Body '{not-json'
    Assert-StatusCode -Id 'E4b' -Name 'bad JSON' -Response $e4b -ExpectedCodes @(400) | Out-Null

    # -------- E5 --------
    Write-Section "E5 type-invalid (observe)"
    $beforeE5 = Get-ProductByEpc -Epc $fixedEpc
    $stBeforeE5 = Get-JsonProperty $beforeE5.Body 'status'
    $e5a = Post-ProductUpdate -JsonBody ("{`"epc`":`"$fixedEpc`",`"read_at`":`"2026-09-28T12:00:00`",`"changes`":{`"status`":123}}")
    $afterE5a = Get-ProductByEpc -Epc $fixedEpc
    Add-Result -Id 'E5a' -Name 'status as number' -Verdict 'OBSERVE' `
        -Expected 'record actual (no whitelist)' `
        -Actual ("HTTP={0} GET status before={1} after={2} body={3}" -f $e5a.StatusCode, $stBeforeE5, (Get-JsonProperty $afterE5a.Body 'status'), $e5a.Raw)
    $e5b = Post-ProductUpdate -JsonBody ("{`"epc`":`"$fixedEpc`",`"read_at`":`"2026-09-28T12:00:00`",`"changes`":{`"status`":[`"OK`"]}}")
    $afterE5b = Get-ProductByEpc -Epc $fixedEpc
    Add-Result -Id 'E5b' -Name 'status as array' -Verdict 'OBSERVE' `
        -Expected 'record actual' `
        -Actual ("HTTP={0} GET status={1} body={2}" -f $e5b.StatusCode, (Get-JsonProperty $afterE5b.Body 'status'), $e5b.Raw)
    $e5c = Post-ProductUpdate -JsonBody '{"epc":12345,"read_at":"2026-09-28T12:00:00","changes":{"status":"OK"}}'
    Add-Result -Id 'E5c' -Name 'epc as number' -Verdict 'OBSERVE' `
        -Expected 'record actual' `
        -Actual ("HTTP={0} body={1} err={2}" -f $e5c.StatusCode, $e5c.Raw, $e5c.Error)

    # -------- E6 --------
    Write-Section "E6 long status (observe)"
    $long30 = ('X' * 31)
    $long50 = ('Y' * 51)
    $beforeE6 = Get-ProductByEpc -Epc $fixedEpc
    $stBeforeE6 = Get-JsonProperty $beforeE6.Body 'status'
    $e6a = Post-ProductUpdate -JsonBody (New-UpdateBody -Epc $fixedEpc -Status $long30)
    $afterE6a = Get-ProductByEpc -Epc $fixedEpc
    $stE6a = Get-JsonProperty $afterE6a.Body 'status'
    Add-Result -Id 'E6a' -Name 'status len 31' -Verdict 'OBSERVE' `
        -Expected '500 or truncate or accept (tag_mode2 NVarChar(30))' `
        -Actual ("HTTP={0} before={1} afterLen={2} after={3} body={4}" -f $e6a.StatusCode, $stBeforeE6, ("$stE6a").Length, $stE6a, $e6a.Raw)
    $e6b = Post-ProductUpdate -JsonBody (New-UpdateBody -Epc $fixedEpc -Status $long50)
    $afterE6b = Get-ProductByEpc -Epc $fixedEpc
    $stE6b = Get-JsonProperty $afterE6b.Body 'status'
    Add-Result -Id 'E6b' -Name 'status len 51' -Verdict 'OBSERVE' `
        -Expected '500 or truncate or accept' `
        -Actual ("HTTP={0} afterLen={1} after={2} body={3}" -f $e6b.StatusCode, ("$stE6b").Length, $stE6b, $e6b.Raw)

    # Mid reset to known ASCII status
    $null = Post-ProductUpdate -JsonBody (New-UpdateBody -Epc $fixedEpc -Status 'STAGING_MID' -UserId '1')

    # -------- D1 --------
    Write-Section "D1 double submit sequential"
    $d1aStatus = 'STAGING_D1A'
    $d1bStatus = 'STAGING_D1B'
    $rD1a = Post-ProductUpdate -JsonBody (New-UpdateBody -Epc $fixedEpc -Status $d1aStatus -UserId '1')
    $rD1b = Post-ProductUpdate -JsonBody (New-UpdateBody -Epc $fixedEpc -Status $d1bStatus -UserId '1')
    $gD1 = Get-ProductByEpc -Epc $fixedEpc
    $stD1 = Get-JsonProperty $gD1.Body 'status'
    if ($rD1a.StatusCode -eq 200 -and $rD1b.StatusCode -eq 200 -and $stD1 -eq $d1bStatus) {
        Add-Result -Id 'D1' -Name 'double sequential' -Verdict 'PASS' `
            -Expected "both 200, final=$d1bStatus" `
            -Actual ("a=$($rD1a.StatusCode) b=$($rD1b.StatusCode) final=$stD1")
    }
    else {
        Add-Result -Id 'D1' -Name 'double sequential' -Verdict 'FAIL' `
            -Expected "both 200, final=$d1bStatus" `
            -Actual ("a=$($rD1a.StatusCode) b=$($rD1b.StatusCode) final=$stD1 aBody=$($rD1a.Raw) bBody=$($rD1b.Raw)")
    }

    # -------- D2 --------
    Write-Section "D2 double submit parallel"
    $beforeD2 = Get-ProductByEpc -Epc $fixedEpc
    $stBeforeD2 = Get-JsonProperty $beforeD2.Body 'status'
    $d2a = 'STAGING_D2A'
    $d2b = 'STAGING_D2B'
    $jobA = Start-Job -ScriptBlock {
        param($Url, $Epc, $Status)
        $bodyObj = @{ epc = $Epc; read_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); changes = @{ status = $Status }; user_id = '1' }
        $body = $bodyObj | ConvertTo-Json -Compress -Depth 5
        try {
            $r = Invoke-WebRequest -Uri "$Url/api/product-updates" -Method POST -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60 -UseBasicParsing
            return @{ Code = [int]$r.StatusCode; Body = $r.Content }
        }
        catch {
            $code = $null
            if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
            return @{ Code = $code; Body = $_.Exception.Message }
        }
    } -ArgumentList $BaseUrl, $fixedEpc, $d2a
    $jobB = Start-Job -ScriptBlock {
        param($Url, $Epc, $Status)
        $bodyObj = @{ epc = $Epc; read_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); changes = @{ status = $Status }; user_id = '1' }
        $body = $bodyObj | ConvertTo-Json -Compress -Depth 5
        try {
            $r = Invoke-WebRequest -Uri "$Url/api/product-updates" -Method POST -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60 -UseBasicParsing
            return @{ Code = [int]$r.StatusCode; Body = $r.Content }
        }
        catch {
            $code = $null
            if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
            return @{ Code = $code; Body = $_.Exception.Message }
        }
    } -ArgumentList $BaseUrl, $fixedEpc, $d2b
    $null = Wait-Job $jobA, $jobB -Timeout 90
    $outA = Receive-Job $jobA
    $outB = Receive-Job $jobB
    Remove-Job $jobA, $jobB -Force -ErrorAction SilentlyContinue
    $gD2 = Get-ProductByEpc -Epc $fixedEpc
    $stD2 = Get-JsonProperty $gD2.Body 'status'
    $finalOk = ($stD2 -eq $d2a -or $stD2 -eq $d2b)
    Add-Result -Id 'D2' -Name 'double parallel' -Verdict $(if ($finalOk) { 'OBSERVE' } else { 'FAIL' }) `
        -Expected 'both may succeed; final is one of the two statuses' `
        -Actual ("before=$stBeforeD2 aCode=$($outA.Code) bCode=$($outB.Code) final=$stD2 aBody=$($outA.Body) bBody=$($outB.Body)") `
        -Notes 'No exclusive lock; last-writer-wins expected'

    # -------- C1 --------
    Write-Section "C1 short timeout (observe consistency)"
    $beforeC1 = Get-ProductByEpc -Epc $fixedEpc
    $stBeforeC1 = Get-JsonProperty $beforeC1.Body 'status'
    $c1Target = 'STAGING_C1'
    $rC1 = Post-ProductUpdate -JsonBody (New-UpdateBody -Epc $fixedEpc -Status $c1Target -UserId '1') -TimeoutSec 1
    Start-Sleep -Seconds 2
    $afterC1 = Get-ProductByEpc -Epc $fixedEpc
    $stAfterC1 = Get-JsonProperty $afterC1.Body 'status'
    $noteC1 = if ($rC1.ClientFailed -or $null -eq $rC1.StatusCode) {
        if ($stAfterC1 -eq $c1Target) { 'client failed but DB shows target status (server may have committed)' }
        elseif ($stAfterC1 -eq $stBeforeC1) { 'client failed and DB unchanged' }
        else { "client failed; DB moved to unexpected status='$stAfterC1'" }
    }
    else {
        "client got HTTP $($rC1.StatusCode); DB status='$stAfterC1'"
    }
    Add-Result -Id 'C1' -Name 'timeout disconnect' -Verdict 'OBSERVE' `
        -Expected 'do NOT require no-update; record consistency' `
        -Actual ("clientFailed=$($rC1.ClientFailed) HTTP=$($rC1.StatusCode) before=$stBeforeC1 after=$stAfterC1 target=$c1Target err=$($rC1.Error)") `
        -Notes $noteC1

    # -------- C2 --------
    Write-Section "C2 cancel mid-request (observe consistency)"
    $beforeC2 = Get-ProductByEpc -Epc $fixedEpc
    $stBeforeC2 = Get-JsonProperty $beforeC2.Body 'status'
    $c2Target = 'STAGING_C2'
    $bodyC2 = New-UpdateBody -Epc $fixedEpc -Status $c2Target -UserId '1'
    $c2ClientMsg = ''
    $c2Cancelled = $false
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $handler = New-Object System.Net.Http.HttpClientHandler
        $client = New-Object System.Net.Http.HttpClient($handler)
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter(50)
        $content = New-Object System.Net.Http.StringContent($bodyC2, [System.Text.Encoding]::UTF8, 'application/json')
        $task = $client.PostAsync("$BaseUrl/api/product-updates", $content, $cts.Token)
        try {
            $httpResp = $task.GetAwaiter().GetResult()
            $c2ClientMsg = "HTTP $([int]$httpResp.StatusCode)"
            $c2Cancelled = $false
        }
        catch {
            $c2Cancelled = $true
            $c2ClientMsg = $_.Exception.GetType().FullName + ': ' + $_.Exception.Message
        }
        finally {
            $client.Dispose()
            $cts.Dispose()
        }
    }
    catch {
        $c2Cancelled = $true
        $c2ClientMsg = $_.Exception.Message
    }
    Start-Sleep -Seconds 2
    $afterC2 = Get-ProductByEpc -Epc $fixedEpc
    $stAfterC2 = Get-JsonProperty $afterC2.Body 'status'
    $noteC2 = if ($c2Cancelled) {
        if ($stAfterC2 -eq $c2Target) { 'cancelled on client but DB shows target (server may have committed)' }
        elseif ($stAfterC2 -eq $stBeforeC2) { 'cancelled; DB unchanged' }
        else { "cancelled; DB unexpected status='$stAfterC2'" }
    } else {
        "request completed: $c2ClientMsg; DB='$stAfterC2'"
    }
    Add-Result -Id 'C2' -Name 'cancel mid-request' -Verdict 'OBSERVE' `
        -Expected 'do NOT require no-update; record consistency' `
        -Actual ("cancelled=$c2Cancelled before=$stBeforeC2 after=$stAfterC2 target=$c2Target msg=$c2ClientMsg") `
        -Notes $noteC2

}
finally {
    Restore-OriginalStatus
}

Write-Section "SUMMARY"
$pass = @($results | Where-Object { $_.Verdict -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.Verdict -eq 'FAIL' }).Count
$obs  = @($results | Where-Object { $_.Verdict -eq 'OBSERVE' }).Count
Write-Host ("PASS={0} FAIL={1} OBSERVE={2} restored={3} epc={4} originalStatus='{5}'" -f $pass, $fail, $obs, $restored, $fixedEpc, $originalStatus)

$results | ForEach-Object {
    Write-Host ("{0,-4} {1,-8} {2,-24} {3}" -f $_.Id, $_.Verdict, $_.Name, $_.Actual)
}

$summaryPath = Join-Path $PSScriptRoot 'test-product-updates-staging-last-result.json'
$payload = [pscustomobject]@{
    ranAt          = (Get-Date).ToString('o')
    baseUrl        = $BaseUrl
    epc            = $fixedEpc
    originalStatus = $originalStatus
    restored       = $restored
    pass           = $pass
    fail           = $fail
    observe        = $obs
    results        = $results
}
$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host "Wrote $summaryPath"

if (-not $restored) { exit 3 }
if ($fail -gt 0) { exit 1 }
exit 0
