#Requires -Version 5.1
<#
.SYNOPSIS
  POST /api/products/tag-ledger staging-only tests.
  Allowed change: this script only. Does not modify API/Flutter code or prod settings.
  Source is ASCII-only so Windows PowerShell 5.1 parses reliably.

.NOTES
  Cleanup uses local test DB (OOMIYADB) via SqlClient DELETE of inserted test EPCs only.
  Requires: staging BaseUrl exact match, readOnly=false, databaseKind!=Production.
  Run only after reviewing proposed ProductCode / EPCs / ManualNumber.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net',
    [int]$ProductCode = 1001,
    [int]$ManualNumber = 7,
    [int]$ExistingNumberForDup = 5,
    [string]$EpcManual = 'stgledger20260929m01',
    [string]$EpcAuto = 'stgledger20260929a01',
    [string]$EpcName = 'stgledger20260929n01',
    [string]$EpcUserIdOnly = 'stgledger20260929u01',
    [string]$EpcParallelSame = 'stgledger20260929p01',
    [string]$EpcParallelDupNumA = 'stgledger20260929p02',
    [string]$EpcParallelDupNumB = 'stgledger20260929p03',
    [string]$EpcDupNumberProbe = 'stgledger20260929d01',
    [int]$MissingProductCode = 654322,
    [string]$SqlServer = 'localhost\SQLEXPRESS',
    [string]$SqlDatabase = 'OOMIYADB',
    [switch]$SkipParallel
)

$ErrorActionPreference = 'Stop'
$AllowedBaseUrl = 'https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net'

if ($BaseUrl -ne $AllowedBaseUrl) {
    Write-Error "REFUSED: BaseUrl must exactly match staging URL.`n  given : '$BaseUrl'`n  allowed: '$AllowedBaseUrl'"
    exit 2
}
if ($SqlDatabase -ne 'OOMIYADB') {
    Write-Error "REFUSED: SqlDatabase must be OOMIYADB (test DB). got='$SqlDatabase'"
    exit 2
}
if ($SqlServer -match '(?i)prod') {
    Write-Error "REFUSED: SqlServer looks like production. got='$SqlServer'"
    exit 2
}

$results = New-Object System.Collections.Generic.List[object]
$insertedEpcs = New-Object System.Collections.Generic.List[string]
$cleanupOk = $false
$snapshotBefore = $null
$ledgerCountBefore = $null

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

function Get-SqlConnectionString {
    return ("Server={0};Database={1};Trusted_Connection=True;TrustServerCertificate=True;" -f $SqlServer, $SqlDatabase)
}

function Invoke-SqlScalar([string]$Sql, $Parameters = @{}) {
    $cs = Get-SqlConnectionString
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql
        foreach ($k in $Parameters.Keys) {
            $null = $cmd.Parameters.AddWithValue($k, $Parameters[$k])
        }
        $val = $cmd.ExecuteScalar()
        if ($val -is [DBNull]) { return $null }
        return $val
    }
    finally { $conn.Close() }
}

function Invoke-SqlQuery([string]$Sql, $Parameters = @{}) {
    $cs = Get-SqlConnectionString
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql
        foreach ($k in $Parameters.Keys) {
            $null = $cmd.Parameters.AddWithValue($k, $Parameters[$k])
        }
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)
        # Prevent PowerShell from unrolling DataTable into DataRow[]
        return ,$dt
    }
    finally { $conn.Close() }
}

function Invoke-SqlNonQuery([string]$Sql, $Parameters = @{}) {
    $cs = Get-SqlConnectionString
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql
        foreach ($k in $Parameters.Keys) {
            $null = $cmd.Parameters.AddWithValue($k, $Parameters[$k])
        }
        return $cmd.ExecuteNonQuery()
    }
    finally { $conn.Close() }
}

function Get-LedgerRowByEpc([string]$Epc) {
    $sql = @"
SELECT
  LTRIM(RTRIM([tag_id2])) AS tag_id2,
  [商品ｺｰﾄﾞ] AS product_code,
  [番号] AS number,
  [tag_mode2] AS tag_mode2,
  [担当者名] AS staff_name,
  [取得日] AS acquired_at,
  [updated] AS updated_at,
  [registration_date] AS registration_date
FROM [dbo].[ICタグ台帳]
WHERE LTRIM(RTRIM([tag_id2])) = @epc
"@
    return Invoke-SqlQuery -Sql $sql -Parameters @{ '@epc' = $Epc }
}

function Count-LedgerByEpc([string]$Epc) {
    $sql = "SELECT COUNT(1) FROM [dbo].[ICタグ台帳] WHERE LTRIM(RTRIM([tag_id2])) = @epc"
    return [int](Invoke-SqlScalar -Sql $sql -Parameters @{ '@epc' = $Epc })
}

function Count-LedgerByCodeNumber([int]$Code, [int]$Number) {
    $sql = "SELECT COUNT(1) FROM [dbo].[ICタグ台帳] WHERE [商品ｺｰﾄﾞ] = @code AND [番号] = @number"
    return [int](Invoke-SqlScalar -Sql $sql -Parameters @{ '@code' = $Code; '@number' = $Number })
}

function Count-TagTable3 {
    return [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[tag_table3]")
}

function Count-TagTable4 {
    return [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[tag_table4]")
}

function Count-LedgerTotal {
    return [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[ICタグ台帳]")
}

function Track-InsertedEpc([string]$Epc) {
    if (-not [string]::IsNullOrWhiteSpace($Epc) -and -not $insertedEpcs.Contains($Epc)) {
        $insertedEpcs.Add($Epc) | Out-Null
    }
}

function New-RegisterBody {
    param(
        [string]$Epc,
        [int]$ProductCode,
        [Nullable[int]]$Number = $null,
        [bool]$AutoNumber = $false,
        [string]$UserId = $null,
        [string]$UserName = $null
    )
    $obj = [ordered]@{
        epc          = $Epc
        product_code = $ProductCode
        auto_number  = $AutoNumber
    }
    if ($null -ne $Number) { $obj['number'] = [int]$Number }
    if ($null -ne $UserId) { $obj['user_id'] = $UserId }
    if ($null -ne $UserName) { $obj['user_name'] = $UserName }
    return ($obj | ConvertTo-Json -Compress -Depth 5)
}

function Find-InTagLedgerList([string]$Epc) {
    $resp = Invoke-ApiRequest -Method GET -Path '/api/products/tag-ledger'
    if ($resp.StatusCode -ne 200) {
        return [pscustomobject]@{ Ok = $false; Response = $resp; Match = $null; Count = 0 }
    }
    $items = @($resp.Body)
    $matches = @($items | Where-Object {
        $t = Get-JsonProperty $_ 'tagId2'
        if (-not $t) { $t = Get-JsonProperty $_ 'TagId2' }
        ("$t").Trim() -ieq $Epc
    })
    return [pscustomobject]@{
        Ok       = $true
        Response = $resp
        Match    = $(if ($matches.Count -gt 0) { $matches[0] } else { $null })
        Count    = $matches.Count
        Total    = $items.Count
    }
}

function Invoke-CleanupInsertedRows {
    Write-Section "CLEANUP: DELETE inserted test EPCs only"
    if ($insertedEpcs.Count -eq 0) {
        Write-Host "No tracked inserted EPCs." -ForegroundColor Yellow
        # still scrub known test EPC prefixes in case partial track failure
    }
    $allCandidates = New-Object System.Collections.Generic.List[string]
    foreach ($e in $insertedEpcs) { if (-not $allCandidates.Contains($e)) { $allCandidates.Add($e) | Out-Null } }
    foreach ($e in @($EpcManual, $EpcAuto, $EpcName, $EpcUserIdOnly, $EpcParallelSame, $EpcParallelDupNumA, $EpcParallelDupNumB, $EpcDupNumberProbe)) {
        if (-not [string]::IsNullOrWhiteSpace($e) -and -not $allCandidates.Contains($e)) {
            $allCandidates.Add($e) | Out-Null
        }
    }

    $deleted = 0
    $remaining = New-Object System.Collections.Generic.List[string]
    foreach ($epc in $allCandidates) {
        $before = Count-LedgerByEpc -Epc $epc
        if ($before -gt 0) {
            $n = Invoke-SqlNonQuery -Sql "DELETE FROM [dbo].[ICタグ台帳] WHERE LTRIM(RTRIM([tag_id2])) = @epc" -Parameters @{ '@epc' = $epc }
            $deleted += [int]$n
            Write-Host "Deleted epc=$epc rows=$n"
        }
        $after = Count-LedgerByEpc -Epc $epc
        if ($after -ne 0) { $remaining.Add($epc) | Out-Null }
    }

    $ledgerAfter = Count-LedgerTotal
    Write-Host ("cleanup deleted={0} remainingBad={1} ledgerTotal before={2} after={3}" -f `
        $deleted, $remaining.Count, $ledgerCountBefore, $ledgerAfter)

    if ($remaining.Count -gt 0) {
        Write-Host ("CLEANUP FAILED: still present: " + ($remaining -join ', ')) -ForegroundColor Red
        $script:cleanupOk = $false
        Add-Result -Id 'CLEANUP' -Name 'delete test EPCs' -Verdict 'FAIL' `
            -Expected 'all test EPCs removed' `
            -Actual ("remaining=" + ($remaining -join ','))
        return $false
    }

    # Integrity: non-test rows should be unchanged in count if we only inserted then deleted
    # Allow equal totals; if after > before something else inserted; if after < before we deleted too much.
    if ($null -ne $ledgerCountBefore -and $ledgerAfter -ne $ledgerCountBefore) {
        # soft note: parallel races may leave extra rows that we also delete; after should return to before
        Add-Result -Id 'CLEANUP' -Name 'delete test EPCs' -Verdict 'FAIL' `
            -Expected ("ledger total restored to $ledgerCountBefore") `
            -Actual ("ledgerTotalAfter=$ledgerAfter deleted=$deleted")
        $script:cleanupOk = $false
        return $false
    }

    Add-Result -Id 'CLEANUP' -Name 'delete test EPCs' -Verdict 'PASS' `
        -Expected ("ledger total=$ledgerCountBefore; test EPCs gone") `
        -Actual ("deleted=$deleted ledgerTotalAfter=$ledgerAfter")
    $script:cleanupOk = $true
    return $true
}

function Post-Register([string]$JsonBody) {
    return Invoke-ApiRequest -Method POST -Path '/api/products/tag-ledger' -Body $JsonBody
}

try {
    Write-Section "GATE: BaseUrl exact match"
    Write-Host "BaseUrl=$BaseUrl"
    Write-Host "SqlServer=$SqlServer SqlDatabase=$SqlDatabase"

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

    Write-Section "GATE: SQL test DB reachable + fingerprint"
    $dbName = [string](Invoke-SqlScalar -Sql "SELECT DB_NAME()")
    if ($dbName -ne 'OOMIYADB') {
        Write-Error "REFUSED: connected DB_NAME()='$dbName' (expected OOMIYADB)"
        exit 2
    }
    # Cross-check staging API and local DB see the same sample product code
    $prodExistsApi = Invoke-ApiRequest -Method GET -Path ("/api/products/tag-ledger/next-number?code=" + $ProductCode)
    if ($prodExistsApi.StatusCode -ne 200) {
        Write-Error "REFUSED: next-number failed for ProductCode=$ProductCode : $($prodExistsApi.Raw)"
        exit 2
    }
    $apiNext = [int](Get-JsonProperty $prodExistsApi.Body 'nextNumber')
    $sqlNext = [int](Invoke-SqlScalar -Sql "SELECT ISNULL(MAX([番号]),0)+1 FROM [dbo].[ICタグ台帳] WHERE [商品ｺｰﾄﾞ]=@code" -Parameters @{ '@code' = $ProductCode })
    if ($apiNext -ne $sqlNext) {
        Write-Error "REFUSED: staging API and local OOMIYADB next-number mismatch. api=$apiNext sql=$sqlNext (abort; may not be same DB)"
        exit 2
    }
    Write-Host "SQL fingerprint OK: ProductCode=$ProductCode nextNumber=$apiNext"
    if ($ManualNumber -ne $apiNext) {
        Write-Host "WARN: ManualNumber=$ManualNumber differs from current nextNumber=$apiNext (will still try ManualNumber)" -ForegroundColor Yellow
    }

    Write-Section "PRECHECK: test EPCs must be absent"
    $testEpcs = @($EpcManual, $EpcAuto, $EpcName, $EpcUserIdOnly, $EpcParallelSame, $EpcParallelDupNumA, $EpcParallelDupNumB, $EpcDupNumberProbe)
    foreach ($epc in $testEpcs) {
        $c = Count-LedgerByEpc -Epc $epc
        if ($c -ne 0) {
            Write-Error "REFUSED: test EPC already exists in ledger: $epc count=$c. Clean first."
            exit 2
        }
    }
    $dupExists = Count-LedgerByCodeNumber -Code $ProductCode -Number $ExistingNumberForDup
    if ($dupExists -lt 1) {
        Write-Error "REFUSED: ExistingNumberForDup=$ExistingNumberForDup not found for ProductCode=$ProductCode"
        exit 2
    }
    $manualFree = Count-LedgerByCodeNumber -Code $ProductCode -Number $ManualNumber
    if ($manualFree -ne 0) {
        Write-Error "REFUSED: ManualNumber=$ManualNumber already used for ProductCode=$ProductCode"
        exit 2
    }
    Write-Host "Precheck OK"

    Write-Section "SNAPSHOT before"
    $ledgerCountBefore = Count-LedgerTotal
    $t3Before = Count-TagTable3
    $t4Before = Count-TagTable4
    $snapshotBefore = [pscustomobject]@{
        ledgerTotal = $ledgerCountBefore
        tagTable3   = $t3Before
        tagTable4   = $t4Before
        productCode = $ProductCode
        nextNumber  = $apiNext
    }
    Write-Host ($snapshotBefore | ConvertTo-Json -Compress)

    # -------- B1-1 manual register --------
    Write-Section "B1-1 manual number register"
    $bodyB11 = New-RegisterBody -Epc $EpcManual -ProductCode $ProductCode -Number $ManualNumber -AutoNumber:$false -UserName 'staging-test'
    $rB11 = Post-Register -JsonBody $bodyB11
    if ($rB11.StatusCode -eq 200) { Track-InsertedEpc $EpcManual }
    $rowB11 = Get-LedgerRowByEpc -Epc $EpcManual
    $modeB11 = if ($rowB11.Rows.Count -gt 0) { [string]$rowB11.Rows[0]['tag_mode2'] } else { $null }
    $numB11 = if ($rowB11.Rows.Count -gt 0) { [int]$rowB11.Rows[0]['number'] } else { $null }
    $codeB11 = if ($rowB11.Rows.Count -gt 0) { [int]$rowB11.Rows[0]['product_code'] } else { $null }
    $okB11 = ($rB11.StatusCode -eq 200) -and ($rowB11.Rows.Count -eq 1) -and ($modeB11 -eq '登録') `
        -and ($numB11 -eq $ManualNumber) -and ($codeB11 -eq $ProductCode)
    if ($okB11) {
        Add-Result -Id 'B1-1' -Name 'manual register' -Verdict 'PASS' `
            -Expected "200; 1 row; mode=登録; number=$ManualNumber" `
            -Actual ("HTTP={0} rows={1} mode={2} number={3} body={4}" -f $rB11.StatusCode, $rowB11.Rows.Count, $modeB11, $numB11, $rB11.Raw)
    }
    else {
        Add-Result -Id 'B1-1' -Name 'manual register' -Verdict 'FAIL' `
            -Expected "200; 1 row; mode=登録; number=$ManualNumber" `
            -Actual ("HTTP={0} rows={1} mode={2} number={3} body={4} err={5}" -f $rB11.StatusCode, $rowB11.Rows.Count, $modeB11, $numB11, $rB11.Raw, $rB11.Error)
    }

    # -------- B1-2 auto_number --------
    Write-Section "B1-2 auto_number"
    $expectAuto = [int](Invoke-SqlScalar -Sql "SELECT ISNULL(MAX([番号]),0)+1 FROM [dbo].[ICタグ台帳] WHERE [商品ｺｰﾄﾞ]=@code" -Parameters @{ '@code' = $ProductCode })
    $bodyB12 = New-RegisterBody -Epc $EpcAuto -ProductCode $ProductCode -AutoNumber:$true -UserName 'staging-test'
    $rB12 = Post-Register -JsonBody $bodyB12
    if ($rB12.StatusCode -eq 200) { Track-InsertedEpc $EpcAuto }
    $respNum = Get-JsonProperty $rB12.Body 'number'
    $rowB12 = Get-LedgerRowByEpc -Epc $EpcAuto
    $dbNum = if ($rowB12.Rows.Count -gt 0) { [int]$rowB12.Rows[0]['number'] } else { $null }
    $okB12 = ($rB12.StatusCode -eq 200) -and ($rowB12.Rows.Count -eq 1) -and ($dbNum -eq $expectAuto) -and ([int]$respNum -eq $expectAuto)
    if ($okB12) {
        Add-Result -Id 'B1-2' -Name 'auto_number' -Verdict 'PASS' `
            -Expected "200; number=$expectAuto" `
            -Actual ("HTTP={0} respNumber={1} dbNumber={2} body={3}" -f $rB12.StatusCode, $respNum, $dbNum, $rB12.Raw)
    }
    else {
        Add-Result -Id 'B1-2' -Name 'auto_number' -Verdict 'FAIL' `
            -Expected "200; number=$expectAuto" `
            -Actual ("HTTP={0} respNumber={1} dbNumber={2} body={3} err={4}" -f $rB12.StatusCode, $respNum, $dbNum, $rB12.Raw, $rB12.Error)
    }

    # -------- B1-3 user_name --------
    Write-Section "B1-3 user_name recorded"
    $nextB13 = [int](Invoke-SqlScalar -Sql "SELECT ISNULL(MAX([番号]),0)+1 FROM [dbo].[ICタグ台帳] WHERE [商品ｺｰﾄﾞ]=@code" -Parameters @{ '@code' = $ProductCode })
    $bodyB13 = New-RegisterBody -Epc $EpcName -ProductCode $ProductCode -Number $nextB13 -AutoNumber:$false -UserName 'tag-ledger-tester'
    $rB13 = Post-Register -JsonBody $bodyB13
    if ($rB13.StatusCode -eq 200) { Track-InsertedEpc $EpcName }
    $rowB13 = Get-LedgerRowByEpc -Epc $EpcName
    $staff = if ($rowB13.Rows.Count -gt 0) { [string]$rowB13.Rows[0]['staff_name'] } else { $null }
    if ($rB13.StatusCode -eq 200 -and $rowB13.Rows.Count -eq 1 -and $staff -eq 'tag-ledger-tester') {
        Add-Result -Id 'B1-3' -Name 'user_name stored' -Verdict 'PASS' `
            -Expected '担当者名=tag-ledger-tester' -Actual ("HTTP={0} staff={1}" -f $rB13.StatusCode, $staff)
    }
    else {
        Add-Result -Id 'B1-3' -Name 'user_name stored' -Verdict 'FAIL' `
            -Expected '担当者名=tag-ledger-tester' `
            -Actual ("HTTP={0} staff={1} rows={2} body={3}" -f $rB13.StatusCode, $staff, $rowB13.Rows.Count, $rB13.Raw)
    }

    # -------- B1-4 user_id ignored --------
    Write-Section "B1-4 user_id ignored (staff NULL)"
    $nextB14 = [int](Invoke-SqlScalar -Sql "SELECT ISNULL(MAX([番号]),0)+1 FROM [dbo].[ICタグ台帳] WHERE [商品ｺｰﾄﾞ]=@code" -Parameters @{ '@code' = $ProductCode })
    $bodyB14 = New-RegisterBody -Epc $EpcUserIdOnly -ProductCode $ProductCode -Number $nextB14 -AutoNumber:$false -UserId '51'
    $rB14 = Post-Register -JsonBody $bodyB14
    if ($rB14.StatusCode -eq 200) { Track-InsertedEpc $EpcUserIdOnly }
    $rowB14 = Get-LedgerRowByEpc -Epc $EpcUserIdOnly
    $staff14 = $null
    $staffIsNull = $false
    if ($rowB14.Rows.Count -gt 0) {
        if ($rowB14.Rows[0].IsNull('staff_name')) { $staffIsNull = $true }
        else { $staff14 = [string]$rowB14.Rows[0]['staff_name'] }
    }
    if ($rB14.StatusCode -eq 200 -and $rowB14.Rows.Count -eq 1 -and $staffIsNull) {
        Add-Result -Id 'B1-4' -Name 'user_id unused' -Verdict 'PASS' `
            -Expected '200; 担当者名 NULL' -Actual ("HTTP={0} staffIsNull={1}" -f $rB14.StatusCode, $staffIsNull)
    }
    else {
        Add-Result -Id 'B1-4' -Name 'user_id unused' -Verdict 'FAIL' `
            -Expected '200; 担当者名 NULL' `
            -Actual ("HTTP={0} staffIsNull={1} staff={2} body={3}" -f $rB14.StatusCode, $staffIsNull, $staff14, $rB14.Raw)
    }

    # -------- B1-5 confirm via GET tag-ledger list (no epc query) OR SELECT --------
    Write-Section "B1-5 confirm via GET /api/products/tag-ledger list + SELECT"
    $find = Find-InTagLedgerList -Epc $EpcManual
    $sqlRow = Get-LedgerRowByEpc -Epc $EpcManual
    $listOk = $find.Ok -and ($find.Count -eq 1)
    $sqlOk = ($sqlRow.Rows.Count -eq 1)
    $listCode = $null; $listNum = $null
    if ($find.Match) {
        $listCode = Get-JsonProperty $find.Match 'productCode'
        if ($null -eq $listCode) { $listCode = Get-JsonProperty $find.Match 'ProductCode' }
        $listNum = Get-JsonProperty $find.Match 'number'
        if ($null -eq $listNum) { $listNum = Get-JsonProperty $find.Match 'Number' }
    }
    if ($listOk -and $sqlOk -and ([int]$listCode -eq $ProductCode) -and ([int]$listNum -eq $ManualNumber)) {
        Add-Result -Id 'B1-5' -Name 'list+SELECT confirm' -Verdict 'PASS' `
            -Expected "found once in GET tag-ledger list; SELECT matches code=$ProductCode number=$ManualNumber" `
            -Actual ("listCount={0} listCode={1} listNum={2} sqlRows={3} ledgerTotalFetched={4}" -f `
                $find.Count, $listCode, $listNum, $sqlRow.Rows.Count, $find.Total)
    }
    else {
        Add-Result -Id 'B1-5' -Name 'list+SELECT confirm' -Verdict 'FAIL' `
            -Expected "found once in GET tag-ledger list; SELECT matches" `
            -Actual ("listOk={0} listCount={1} listCode={2} listNum={3} sqlRows={4} http={5}" -f `
                $find.Ok, $find.Count, $listCode, $listNum, $sqlRow.Rows.Count, $find.Response.StatusCode)
    }

    # -------- B2 validation --------
    Write-Section "B2 validation errors (DB unchanged for that case)"
    $tBeforeB2 = Count-LedgerTotal
    $b21 = Post-Register -JsonBody '{"product_code":1001,"number":1,"auto_number":false}'
    Assert-StatusCode -Id 'B2-1a' -Name 'epc missing' -Response $b21 -ExpectedCodes @(400) | Out-Null
    $b21b = Post-Register -JsonBody '{"epc":"","product_code":1001,"number":1,"auto_number":false}'
    Assert-StatusCode -Id 'B2-1b' -Name 'epc empty' -Response $b21b -ExpectedCodes @(400) | Out-Null
    $b22 = Post-Register -JsonBody ("{`"epc`":`"stgledger-invalid-temp`",`"product_code`":0,`"number`":1,`"auto_number`":false}")
    Assert-StatusCode -Id 'B2-2' -Name 'product_code <=0' -Response $b22 -ExpectedCodes @(400) | Out-Null
    $b23 = Post-Register -JsonBody ("{`"epc`":`"stgledger-invalid-temp2`",`"product_code`":$ProductCode,`"auto_number`":false}")
    Assert-StatusCode -Id 'B2-3' -Name 'number missing when not auto' -Response $b23 -ExpectedCodes @(400) | Out-Null
    $b24 = Post-Register -JsonBody ("{`"epc`":`"stgledger-missing-prod`",`"product_code`":$MissingProductCode,`"number`":1,`"auto_number`":false}")
    Assert-StatusCode -Id 'B2-4' -Name 'missing product' -Response $b24 -ExpectedCodes @(404) | Out-Null
    $b25 = Invoke-ApiRequest -Method POST -Path '/api/products/tag-ledger' -Body '{not-json'
    Assert-StatusCode -Id 'B2-5' -Name 'bad JSON' -Response $b25 -ExpectedCodes @(400) | Out-Null
    $tAfterB2 = Count-LedgerTotal
    if ($tAfterB2 -eq $tBeforeB2) {
        Add-Result -Id 'B2-DB' -Name 'validation left ledger count unchanged' -Verdict 'PASS' `
            -Expected "ledgerTotal=$tBeforeB2" -Actual "ledgerTotal=$tAfterB2"
    }
    else {
        Add-Result -Id 'B2-DB' -Name 'validation left ledger count unchanged' -Verdict 'FAIL' `
            -Expected "ledgerTotal=$tBeforeB2" -Actual "ledgerTotal=$tAfterB2"
    }

    # -------- B3 duplicate / resubmit --------
    Write-Section "B3 duplicate / resubmit"
    $rB31 = Post-Register -JsonBody (New-RegisterBody -Epc $EpcManual -ProductCode $ProductCode -Number $ManualNumber -AutoNumber:$false)
    $cntB31 = Count-LedgerByEpc -Epc $EpcManual
    if ($rB31.StatusCode -eq 409 -and $cntB31 -eq 1) {
        Add-Result -Id 'B3-1' -Name 'same EPC resubmit' -Verdict 'PASS' `
            -Expected '409 and still 1 row' -Actual ("HTTP={0} rows={1} body={2}" -f $rB31.StatusCode, $cntB31, $rB31.Raw)
    }
    else {
        Add-Result -Id 'B3-1' -Name 'same EPC resubmit' -Verdict 'FAIL' `
            -Expected '409 and still 1 row' -Actual ("HTTP={0} rows={1} body={2}" -f $rB31.StatusCode, $cntB31, $rB31.Raw)
        if ($cntB31 -gt 1) {
            Add-Result -Id 'B3-1-DUP' -Name 'EPC duplicate rows' -Verdict 'FAIL' `
                -Expected 'exactly 1 row for EPC' -Actual "rows=$cntB31"
        }
    }

    $nextB32 = [int](Invoke-SqlScalar -Sql "SELECT ISNULL(MAX([番号]),0)+1 FROM [dbo].[ICタグ台帳] WHERE [商品ｺｰﾄﾞ]=@code" -Parameters @{ '@code' = $ProductCode })
    # Use a throwaway EPC for code+number conflict against ExistingNumberForDup
    if ((Count-LedgerByEpc -Epc $EpcDupNumberProbe) -eq 0) {
        $rB32 = Post-Register -JsonBody (New-RegisterBody -Epc $EpcDupNumberProbe -ProductCode $ProductCode -Number $ExistingNumberForDup -AutoNumber:$false)
        if ($rB32.StatusCode -eq 200) { Track-InsertedEpc $EpcDupNumberProbe }
        $cntCombo = Count-LedgerByCodeNumber -Code $ProductCode -Number $ExistingNumberForDup
        if ($rB32.StatusCode -eq 409) {
            Add-Result -Id 'B3-2' -Name 'same product+number' -Verdict 'PASS' `
                -Expected '409' -Actual ("HTTP={0} comboCount={1} body={2}" -f $rB32.StatusCode, $cntCombo, $rB32.Raw)
        }
        else {
            Add-Result -Id 'B3-2' -Name 'same product+number' -Verdict 'FAIL' `
                -Expected '409' -Actual ("HTTP={0} comboCount={1} body={2}" -f $rB32.StatusCode, $cntCombo, $rB32.Raw)
            if ($cntCombo -gt $dupExists -and $rB32.StatusCode -eq 200) {
                Add-Result -Id 'B3-2-DUP' -Name 'product+number duplicated' -Verdict 'FAIL' `
                    -Expected "combo count stays $dupExists" -Actual "comboCount=$cntCombo"
            }
        }
    }
    else {
        Add-Result -Id 'B3-2' -Name 'same product+number' -Verdict 'FAIL' `
            -Expected 'precheck epc free' -Actual "epc=$EpcDupNumberProbe already exists"
    }

    # -------- B4 integrity (side tables unchanged) --------
    Write-Section "B4 side-table integrity"
    $t3Now = Count-TagTable3
    $t4Now = Count-TagTable4
    if ($t3Now -eq $t3Before -and $t4Now -eq $t4Before) {
        Add-Result -Id 'B4-1' -Name 'tag_table3/4 unchanged' -Verdict 'PASS' `
            -Expected "t3=$t3Before t4=$t4Before" -Actual "t3=$t3Now t4=$t4Now"
    }
    else {
        Add-Result -Id 'B4-1' -Name 'tag_table3/4 unchanged' -Verdict 'FAIL' `
            -Expected "t3=$t3Before t4=$t4Before" -Actual "t3=$t3Now t4=$t4Now"
    }

    # -------- B3-4 / B3-5 parallel --------
    if (-not $SkipParallel) {
        Write-Section "B3-4 parallel same EPC (duplicate EPC => FAIL)"
        $beforeP = Count-LedgerByEpc -Epc $EpcParallelSame
        $nextP = [int](Invoke-SqlScalar -Sql "SELECT ISNULL(MAX([番号]),0)+1 FROM [dbo].[ICタグ台帳] WHERE [商品ｺｰﾄﾞ]=@code" -Parameters @{ '@code' = $ProductCode })
        $jobBody = @{
            epc = $EpcParallelSame
            product_code = $ProductCode
            number = $nextP
            auto_number = $false
            user_name = 'parallel'
        } | ConvertTo-Json -Compress
        $jobA = Start-Job -ScriptBlock {
            param($Url, $Body)
            try {
                $r = Invoke-WebRequest -Uri "$Url/api/products/tag-ledger" -Method POST -ContentType 'application/json; charset=utf-8' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -TimeoutSec 60 -UseBasicParsing
                return @{ Code = [int]$r.StatusCode; Body = $r.Content }
            } catch {
                $code = $null
                if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
                return @{ Code = $code; Body = $_.Exception.Message }
            }
        } -ArgumentList $BaseUrl, $jobBody
        $jobB = Start-Job -ScriptBlock {
            param($Url, $Body)
            try {
                $r = Invoke-WebRequest -Uri "$Url/api/products/tag-ledger" -Method POST -ContentType 'application/json; charset=utf-8' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -TimeoutSec 60 -UseBasicParsing
                return @{ Code = [int]$r.StatusCode; Body = $r.Content }
            } catch {
                $code = $null
                if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
                return @{ Code = $code; Body = $_.Exception.Message }
            }
        } -ArgumentList $BaseUrl, $jobBody
        $null = Wait-Job $jobA, $jobB -Timeout 90
        $outA = Receive-Job $jobA
        $outB = Receive-Job $jobB
        Remove-Job $jobA, $jobB -Force -ErrorAction SilentlyContinue
        Track-InsertedEpc $EpcParallelSame
        $afterP = Count-LedgerByEpc -Epc $EpcParallelSame
        $codes = @($outA.Code, $outB.Code)
        # Order of 200/409 is OBSERVE; duplicate rows are FAIL
        Add-Result -Id 'B3-4-ORDER' -Name 'parallel same EPC status order' -Verdict 'OBSERVE' `
            -Expected 'one of 200/409 combinations; order not judged' `
            -Actual ("before=$beforeP a=$($outA.Code) b=$($outB.Code) rows=$afterP aBody=$($outA.Body) bBody=$($outB.Body)")
        if ($afterP -eq 1) {
            Add-Result -Id 'B3-4' -Name 'parallel same EPC no duplicate' -Verdict 'PASS' `
                -Expected 'exactly 1 ledger row for EPC' -Actual "rows=$afterP"
        }
        elseif ($afterP -gt 1) {
            Add-Result -Id 'B3-4' -Name 'parallel same EPC no duplicate' -Verdict 'FAIL' `
                -Expected 'exactly 1 ledger row for EPC' -Actual "rows=$afterP (duplicate EPC registration)"
        }
        else {
            Add-Result -Id 'B3-4' -Name 'parallel same EPC no duplicate' -Verdict 'FAIL' `
                -Expected 'exactly 1 ledger row for EPC' -Actual "rows=$afterP codes=$($codes -join ',')"
        }

        Write-Section "B3-5 parallel auto_number=true (no duplicate numbers)"
        # Both POSTs use auto_number=true (no manual number). UPDLOCK on MAX+1 should yield distinct numbers.
        $bodyAutoA = (@{ epc = $EpcParallelDupNumA; product_code = $ProductCode; auto_number = $true; user_name = 'pA' } | ConvertTo-Json -Compress)
        $bodyAutoB = (@{ epc = $EpcParallelDupNumB; product_code = $ProductCode; auto_number = $true; user_name = 'pB' } | ConvertTo-Json -Compress)
        $jobC = Start-Job -ScriptBlock {
            param($Url, $Body)
            try {
                $r = Invoke-WebRequest -Uri "$Url/api/products/tag-ledger" -Method POST -ContentType 'application/json; charset=utf-8' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -TimeoutSec 60 -UseBasicParsing
                return @{ Code = [int]$r.StatusCode; Body = $r.Content }
            } catch {
                $code = $null
                if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
                return @{ Code = $code; Body = $_.Exception.Message }
            }
        } -ArgumentList $BaseUrl, $bodyAutoA
        $jobD = Start-Job -ScriptBlock {
            param($Url, $Body)
            try {
                $r = Invoke-WebRequest -Uri "$Url/api/products/tag-ledger" -Method POST -ContentType 'application/json; charset=utf-8' `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -TimeoutSec 60 -UseBasicParsing
                return @{ Code = [int]$r.StatusCode; Body = $r.Content }
            } catch {
                $code = $null
                if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
                return @{ Code = $code; Body = $_.Exception.Message }
            }
        } -ArgumentList $BaseUrl, $bodyAutoB
        $null = Wait-Job $jobC, $jobD -Timeout 90
        $outC = Receive-Job $jobC
        $outD = Receive-Job $jobD
        Remove-Job $jobC, $jobD -Force -ErrorAction SilentlyContinue
        Track-InsertedEpc $EpcParallelDupNumA
        Track-InsertedEpc $EpcParallelDupNumB
        $rowA = Get-LedgerRowByEpc -Epc $EpcParallelDupNumA
        $rowB = Get-LedgerRowByEpc -Epc $EpcParallelDupNumB
        $numA = if ($rowA.Rows.Count -gt 0) { [int]$rowA.Rows[0]['number'] } else { $null }
        $numB = if ($rowB.Rows.Count -gt 0) { [int]$rowB.Rows[0]['number'] } else { $null }
        $cntA = Count-LedgerByEpc -Epc $EpcParallelDupNumA
        $cntB = Count-LedgerByEpc -Epc $EpcParallelDupNumB
        Add-Result -Id 'B3-5-ORDER' -Name 'parallel auto_number status order' -Verdict 'OBSERVE' `
            -Expected 'both 200 expected; which finishes first is not judged' `
            -Actual ("aCode=$($outC.Code) bCode=$($outD.Code) numA=$numA numB=$numB aBody=$($outC.Body) bBody=$($outD.Body)")
        # FAIL if duplicate number assigned to both EPCs, or either EPC duplicated, or both did not land as 1 row each
        if ($cntA -eq 1 -and $cntB -eq 1 -and $null -ne $numA -and $null -ne $numB -and $numA -ne $numB) {
            Add-Result -Id 'B3-5' -Name 'parallel auto_number no duplicate number' -Verdict 'PASS' `
                -Expected 'both registered; distinct numbers' `
                -Actual ("numA=$numA numB=$numB cntA=$cntA cntB=$cntB")
        }
        elseif ($null -ne $numA -and $null -ne $numB -and $numA -eq $numB) {
            Add-Result -Id 'B3-5' -Name 'parallel auto_number no duplicate number' -Verdict 'FAIL' `
                -Expected 'distinct numbers for two EPCs' `
                -Actual ("DUPLICATE number=$numA on both EPCs cntA=$cntA cntB=$cntB")
        }
        else {
            Add-Result -Id 'B3-5' -Name 'parallel auto_number no duplicate number' -Verdict 'FAIL' `
                -Expected 'both registered with distinct numbers' `
                -Actual ("numA=$numA numB=$numB cntA=$cntA cntB=$cntB aCode=$($outC.Code) bCode=$($outD.Code)")
        }
    }
    else {
        Add-Result -Id 'B3-4' -Name 'parallel skipped' -Verdict 'OBSERVE' -Expected 'skipped' -Actual 'SkipParallel'
        Add-Result -Id 'B3-5' -Name 'parallel skipped' -Verdict 'OBSERVE' -Expected 'skipped' -Actual 'SkipParallel'
    }
}
catch {
    Write-Host ("TEST ERROR: " + $_.Exception.Message) -ForegroundColor Red
    Add-Result -Id 'SCRIPT' -Name 'uncaught error' -Verdict 'FAIL' `
        -Expected 'no exception' -Actual $_.Exception.Message
}
finally {
    try {
        Invoke-CleanupInsertedRows | Out-Null
    }
    catch {
        $script:cleanupOk = $false
        Add-Result -Id 'CLEANUP' -Name 'delete test EPCs' -Verdict 'FAIL' `
            -Expected 'cleanup succeeds' -Actual $_.Exception.Message
    }
}

Write-Section "SUMMARY"
$pass = @($results | Where-Object { $_.Verdict -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.Verdict -eq 'FAIL' }).Count
$obs  = @($results | Where-Object { $_.Verdict -eq 'OBSERVE' }).Count
Write-Host ("PASS={0} FAIL={1} OBSERVE={2} cleanupOk={3}" -f $pass, $fail, $obs, $cleanupOk)

$results | ForEach-Object {
    Write-Host ("{0,-10} {1,-8} {2,-36} {3}" -f $_.Id, $_.Verdict, $_.Name, $_.Actual)
}

$summaryPath = Join-Path $PSScriptRoot 'test-tag-ledger-staging-last-result.json'
$payload = [pscustomobject]@{
    ranAt           = (Get-Date).ToString('o')
    baseUrl         = $BaseUrl
    sqlServer       = $SqlServer
    sqlDatabase     = $SqlDatabase
    productCode     = $ProductCode
    manualNumber    = $ManualNumber
    existingNumber  = $ExistingNumberForDup
    epcs            = @{
        manual = $EpcManual
        auto = $EpcAuto
        name = $EpcName
        userIdOnly = $EpcUserIdOnly
        parallelSame = $EpcParallelSame
        parallelDupA = $EpcParallelDupNumA
        parallelDupB = $EpcParallelDupNumB
    }
    snapshotBefore  = $snapshotBefore
    cleanupOk       = $cleanupOk
    pass            = $pass
    fail            = $fail
    observe         = $obs
    results         = $results
}
$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host "Wrote $summaryPath"

if (-not $cleanupOk) { exit 3 }
if ($fail -gt 0) { exit 1 }
exit 0
