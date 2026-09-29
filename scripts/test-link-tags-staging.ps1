#Requires -Version 5.1
<#
.SYNOPSIS
  POST /api/reception-slips/{receptionNo}/link-tags staging-only tests.
  Does not modify API/Flutter code or prod Azure settings.
  A3-4 (repost after complete=1 on delivery) is OFF unless -RequireRunDangerousA34.
  -PreCheckOnly: stop after env/table/reception/EPC/count gates (no API POSTs).

.NOTES
  Cleanup: DELETE only tag_table3 rows inserted during this run (by ID).
  Restore: ICタグ台帳.tag_mode2 (+ updated) for used EPCs to pre-test snapshot.
  Side-table integrity: 納品台帳 / 納品明細 / tag_table4 row counts must be unchanged.
  Never bulk-deletes existing tag_table3 rows.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net',

    # A: delivery (<配達>)
    [int]$ReceptionDelivery = 404140,
    [string]$EpcDelivery1 = 'e2006304040e01440720cce0',
    [string]$EpcDelivery2 = '252520241211080500002336',

    # B: pickup (引取)
    [int]$ReceptionPickup = 404133,
    [string]$EpcPickup1 = 'e200001605090224190051cd',
    [string]$EpcPickup2 = 'e2006304040e01750940b536',

    # C: exchange (交換)
    [int]$ReceptionExchange = 404010,
    [string]$EpcExchangeDelivery = 'e2006304040e02110880bca8',
    [string]$EpcExchangeReturn = 'e2000017690c002621203d12',

    [string]$FakeMissingEpc = 'stg-linktags-missing-epc-0001',
    [string]$SqlServer = 'localhost\SQLEXPRESS',
    [string]$SqlDatabase = 'OOMIYADB',
    [switch]$SkipParallel,
    [switch]$RequireRunDangerousA34,
    # 環境ゲート・テーブル存在・受付/EPC・開始件数までで終了（API POST しない）
    [switch]$PreCheckOnly
)

$ErrorActionPreference = 'Stop'
$AllowedBaseUrl = 'https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net'
$ForbiddenHostFragments = @(
    'ohmiyakoki-tagapp-api-prod',
    'tagapp-api-prod',
    'gsdcabb4gzbzcyaw'  # prod hostname fragment from docs
)

if ($BaseUrl -ne $AllowedBaseUrl) {
    Write-Error "REFUSED: BaseUrl must exactly match staging URL.`n  given : '$BaseUrl'`n  allowed: '$AllowedBaseUrl'"
    exit 2
}
foreach ($frag in $ForbiddenHostFragments) {
    if ($BaseUrl -match [regex]::Escape($frag)) {
        Write-Error "REFUSED: BaseUrl contains production host fragment '$frag'"
        exit 2
    }
}
if ($SqlDatabase -ne 'OOMIYADB') {
    Write-Error "REFUSED: SqlDatabase must be OOMIYADB. got='$SqlDatabase'"
    exit 2
}
if ($SqlServer -match '(?i)prod') {
    Write-Error "REFUSED: SqlServer looks like production. got='$SqlServer'"
    exit 2
}

$results = New-Object System.Collections.Generic.List[object]
$cleanupOk = $false
$insertedTagTable3Ids = New-Object System.Collections.Generic.HashSet[int]
$epcSnapshots = @{}          # epc -> @{ mode2; updated }
$receptionT3IdsBefore = @{}  # receptionNo -> HashSet[int]
$sideCountsBefore = $null
$subjD = $null; $subjP = $null; $subjE = $null
$allEpcs = @()

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

function Add-Result {
    param([string]$Id,[string]$Name,[string]$Verdict,[string]$Expected,[string]$Actual,[string]$Notes='')
    $row = [pscustomobject]@{ Id=$Id; Name=$Name; Verdict=$Verdict; Expected=$Expected; Actual=$Actual; Notes=$Notes }
    $results.Add($row) | Out-Null
    $color = switch ($Verdict) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ("[{0}] {1} {2} - {3}" -f $Verdict, $Id, $Name, $Actual) -ForegroundColor $color
    if ($Notes) { Write-Host "         $Notes" -ForegroundColor DarkGray }
}

function Assert-StatusCode {
    param([string]$Id,[string]$Name,$Response,[int[]]$ExpectedCodes,[string]$Notes='')
    $actual = if ($null -eq $Response.StatusCode) { "client-fail: $($Response.Error)" } else { "$($Response.StatusCode) body=$($Response.Raw)" }
    if ($null -ne $Response.StatusCode -and ($ExpectedCodes -contains [int]$Response.StatusCode)) {
        Add-Result -Id $Id -Name $Name -Verdict 'PASS' -Expected ("HTTP " + ($ExpectedCodes -join '|')) -Actual $actual -Notes $Notes
        return $true
    }
    Add-Result -Id $Id -Name $Name -Verdict 'FAIL' -Expected ("HTTP " + ($ExpectedCodes -join '|')) -Actual $actual -Notes $Notes
    return $false
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
            $resp = Invoke-WebRequest -Uri $uri -Method POST -TimeoutSec $TimeoutSec -UseBasicParsing -ContentType $ContentType
        }
        else {
            $resp = Invoke-WebRequest -Uri $uri -Method POST -TimeoutSec $TimeoutSec -UseBasicParsing `
                -ContentType $ContentType -Body ([System.Text.Encoding]::UTF8.GetBytes($Body))
        }
        $sw.Stop()
        $parsed = $null
        if ($resp.Content) { try { $parsed = $resp.Content | ConvertFrom-Json } catch { $parsed = $resp.Content } }
        return [pscustomobject]@{ Ok=$true; StatusCode=[int]$resp.StatusCode; Body=$parsed; Raw=$resp.Content; Error=$null; ElapsedMs=$sw.ElapsedMilliseconds; ClientFailed=$false }
    }
    catch {
        $sw.Stop()
        $ex = $_.Exception
        $statusCode = $null; $raw = $null; $parsed = $null
        if ($ex.Response) {
            try { $statusCode = [int]$ex.Response.StatusCode } catch {}
            try {
                $stream = $ex.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $raw = $reader.ReadToEnd(); $reader.Close()
                    try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $raw }
                }
            } catch {}
        }
        if (-not $statusCode -and $ex.Message -match ',\s*\((\d{3})\)') { $statusCode = [int]$Matches[1] }
        return [pscustomobject]@{ Ok=$false; StatusCode=$statusCode; Body=$parsed; Raw=$raw; Error=$ex.Message; ElapsedMs=$sw.ElapsedMilliseconds; ClientFailed=(-not $statusCode) }
    }
}

function Get-SqlConnectionString {
    return ("Server={0};Database={1};Trusted_Connection=True;TrustServerCertificate=True;" -f $SqlServer, $SqlDatabase)
}

function Invoke-SqlScalar([string]$Sql, $Parameters = @{}) {
    $conn = New-Object System.Data.SqlClient.SqlConnection (Get-SqlConnectionString)
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Sql
        foreach ($k in $Parameters.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Parameters[$k]) }
        $val = $cmd.ExecuteScalar()
        if ($val -is [DBNull]) { return $null }
        return $val
    }
    finally { $conn.Close() }
}

function Invoke-SqlQuery([string]$Sql, $Parameters = @{}) {
    $conn = New-Object System.Data.SqlClient.SqlConnection (Get-SqlConnectionString)
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Sql
        foreach ($k in $Parameters.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Parameters[$k]) }
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)
        Write-Output -NoEnumerate $dt
    }
    finally { $conn.Close() }
}

function Invoke-SqlNonQuery([string]$Sql, $Parameters = @{}) {
    $conn = New-Object System.Data.SqlClient.SqlConnection (Get-SqlConnectionString)
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Sql
        foreach ($k in $Parameters.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Parameters[$k]) }
        return $cmd.ExecuteNonQuery()
    }
    finally { $conn.Close() }
}

function Get-ReceptionSubject([int]$ReceptionNo) {
    $sql = @"
SELECT ISNULL(p.[用件], N'')
FROM [dbo].[受付台帳] r
LEFT JOIN [dbo].[用件台帳] p ON p.[用件コード] = r.[用件コード]
WHERE r.[受付番号] = @n
"@
    return [string](Invoke-SqlScalar -Sql $sql -Parameters @{ '@n' = $ReceptionNo })
}

function Get-TagTable3Ids([int]$ReceptionNo) {
    $dt = Invoke-SqlQuery -Sql "SELECT ID FROM [dbo].[tag_table3] WHERE [受付番号]=@n" -Parameters @{ '@n' = $ReceptionNo }
    $set = New-Object System.Collections.Generic.HashSet[int]
    foreach ($row in $dt.Rows) { [void]$set.Add([int]$row['ID']) }
    # 空集合や単一要素が $null / Object[] に壊れないよう NoEnumerate で返す
    Write-Output -NoEnumerate $set
}

function Normalize-IntHashSet($value) {
    if ($value -is [System.Collections.Generic.HashSet[int]]) {
        Write-Output -NoEnumerate $value
        return
    }
    $set = New-Object System.Collections.Generic.HashSet[int]
    if ($null -ne $value) {
        foreach ($id in @($value)) {
            if ($null -ne $id -and "$id" -ne '') { [void]$set.Add([int]$id) }
        }
    }
    Write-Output -NoEnumerate $set
}

function Get-TagTable3Rows([int]$ReceptionNo, [string]$Epc = $null) {
    if ($Epc) {
        $sql = @"
SELECT ID, LTRIM(RTRIM(tag_id2)) AS epc, ISNULL(tag_mode,N'') AS tag_mode,
  CAST(ISNULL(complete,0) AS int) AS complete, CAST(ISNULL(mark,0) AS int) AS mark,
  CAST(ISNULL([印刷],0) AS int) AS print_flag, s_code
FROM [dbo].[tag_table3]
WHERE [受付番号]=@n AND LTRIM(RTRIM(tag_id2))=@epc
ORDER BY ID
"@
        return Invoke-SqlQuery -Sql $sql -Parameters @{ '@n' = $ReceptionNo; '@epc' = $Epc }
    }
    $sql = @"
SELECT ID, LTRIM(RTRIM(tag_id2)) AS epc, ISNULL(tag_mode,N'') AS tag_mode,
  CAST(ISNULL(complete,0) AS int) AS complete, CAST(ISNULL(mark,0) AS int) AS mark,
  CAST(ISNULL([印刷],0) AS int) AS print_flag, s_code
FROM [dbo].[tag_table3]
WHERE [受付番号]=@n
ORDER BY ID
"@
    return Invoke-SqlQuery -Sql $sql -Parameters @{ '@n' = $ReceptionNo }
}

function Get-LedgerSnapshot([string]$Epc) {
    $sql = @"
SELECT LTRIM(RTRIM(tag_id2)) AS epc, [商品ｺｰﾄﾞ] AS product_code, [番号] AS number,
  ISNULL(tag_mode2, N'') AS tag_mode2, updated
FROM [dbo].[ICタグ台帳]
WHERE LTRIM(RTRIM(tag_id2)) = @epc
"@
    $dt = Invoke-SqlQuery -Sql $sql -Parameters @{ '@epc' = $Epc }
    if ($dt.Rows.Count -eq 0) { return $null }
    $r = $dt.Rows[0]
    return [pscustomobject]@{
        Epc = [string]$r['epc']
        ProductCode = $(if ($r.IsNull('product_code')) { $null } else { [int]$r['product_code'] })
        Number = $(if ($r.IsNull('number')) { $null } else { [int]$r['number'] })
        TagMode2 = [string]$r['tag_mode2']
        Updated = $(if ($r.IsNull('updated')) { $null } else { [datetime]$r['updated'] })
    }
}

function Track-NewTagTable3Ids([int]$ReceptionNo) {
    $now = Normalize-IntHashSet (Get-TagTable3Ids -ReceptionNo $ReceptionNo)
    $before = Normalize-IntHashSet $receptionT3IdsBefore[$ReceptionNo]
    $receptionT3IdsBefore[$ReceptionNo] = $before
    foreach ($id in $now) {
        if (-not $before.Contains($id)) {
            [void]$insertedTagTable3Ids.Add($id)
        }
    }
}

function New-LinkBody {
    param(
        [object[]]$Items,
        [string]$UserId = '51',
        [string]$LinkMode = $null
    )
    $obj = [ordered]@{
        user_id = $UserId
        items   = @($Items)
    }
    if ($LinkMode) { $obj['link_mode'] = $LinkMode }
    return ($obj | ConvertTo-Json -Compress -Depth 6)
}

function Post-LinkTags {
    param([int]$ReceptionNo, [string]$JsonBody)
    return Invoke-ApiRequest -Method POST -Path ("/api/reception-slips/{0}/link-tags" -f $ReceptionNo) -Body $JsonBody
}

function Assert-LedgerAndT3 {
    param(
        [string]$Id,
        [string]$Name,
        [int]$ReceptionNo,
        [string]$Epc,
        [string]$ExpectMode2,
        [string]$ExpectT3Mode,
        [int]$ExpectComplete
    )
    $led = Get-LedgerSnapshot -Epc $Epc
    $t3 = Get-TagTable3Rows -ReceptionNo $ReceptionNo -Epc $Epc
    if ($null -eq $t3) {
        Add-Result -Id $Id -Name $Name -Verdict 'FAIL' `
            -Expected "mode2=$ExpectMode2 t3=$ExpectT3Mode complete=$ExpectComplete rows=1" `
            -Actual 'tag_table3 query returned null' -Notes 'Get-TagTable3Rows null'
        return $false
    }
    $modeOk = ($null -ne $led) -and ($led.TagMode2 -eq $ExpectMode2)
    $t3Ok = ($t3.Rows.Count -eq 1) `
        -and ([string]$t3.Rows[0]['tag_mode'] -eq $ExpectT3Mode) `
        -and ([int]$t3.Rows[0]['complete'] -eq $ExpectComplete) `
        -and ([int]$t3.Rows[0]['mark'] -eq 0) `
        -and ([int]$t3.Rows[0]['print_flag'] -eq 0)
    $dupFail = ($t3.Rows.Count -gt 1)
    if ($modeOk -and $t3Ok -and -not $dupFail) {
        Add-Result -Id $Id -Name $Name -Verdict 'PASS' `
            -Expected "mode2=$ExpectMode2 t3=$ExpectT3Mode complete=$ExpectComplete rows=1" `
            -Actual ("mode2=$($led.TagMode2) t3Rows=$($t3.Rows.Count) t3Mode=$($t3.Rows[0]['tag_mode']) complete=$($t3.Rows[0]['complete'])")
        return $true
    }
    $verdict = 'FAIL'
    $notes = ''
    if ($dupFail) { $notes = 'unintended tag_table3 duplicate rows' }
    elseif (-not $modeOk -or -not $t3Ok) { $notes = 'ledger/tag_table3 inconsistency' }
    Add-Result -Id $Id -Name $Name -Verdict $verdict `
        -Expected "mode2=$ExpectMode2 t3=$ExpectT3Mode complete=$ExpectComplete rows=1" `
        -Actual ("mode2=$(if($led){$led.TagMode2}else{'MISSING'}) t3Rows=$($t3.Rows.Count)") `
        -Notes $notes
    return $false
}

function Invoke-CleanupAndRestore {
    Write-Section "CLEANUP + RESTORE"
    $ok = $true

    # 1) Delete tracked inserted IDs, then any remaining extras vs pre-test snapshot
    $deleted = 0
    foreach ($id in @($insertedTagTable3Ids)) {
        $n = Invoke-SqlNonQuery -Sql "DELETE FROM [dbo].[tag_table3] WHERE ID=@id" -Parameters @{ '@id' = $id }
        $deleted += [int]$n
        Write-Host "Deleted tag_table3 ID=$id rows=$n"
    }
    foreach ($rn in @($ReceptionDelivery, $ReceptionPickup, $ReceptionExchange)) {
        $now = Normalize-IntHashSet (Get-TagTable3Ids -ReceptionNo $rn)
        $before = Normalize-IntHashSet $receptionT3IdsBefore[$rn]
        $extra = @($now | Where-Object { -not $before.Contains([int]$_) })
        foreach ($id in $extra) {
            $n = Invoke-SqlNonQuery -Sql "DELETE FROM [dbo].[tag_table3] WHERE ID=@id" -Parameters @{ '@id' = [int]$id }
            $deleted += [int]$n
            Write-Host "Deleted leftover tag_table3 ID=$id (reception=$rn) rows=$n"
            [void]$insertedTagTable3Ids.Add([int]$id)
        }
    }

    # Verify no leftover inserted IDs
    foreach ($id in @($insertedTagTable3Ids)) {
        $c = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[tag_table3] WHERE ID=@id" -Parameters @{ '@id' = $id })
        if ($c -ne 0) {
            Write-Host "CLEANUP FAIL: tag_table3 ID=$id still exists" -ForegroundColor Red
            $ok = $false
        }
    }

    # 2) Reception tag_table3 ID sets must equal pre-test
    foreach ($rn in @($ReceptionDelivery, $ReceptionPickup, $ReceptionExchange)) {
        $now = Normalize-IntHashSet (Get-TagTable3Ids -ReceptionNo $rn)
        $before = Normalize-IntHashSet $receptionT3IdsBefore[$rn]
        $extra = @($now | Where-Object { -not $before.Contains([int]$_) })
        $missing = @($before | Where-Object { -not $now.Contains([int]$_) })
        if ($extra.Count -gt 0 -or $missing.Count -gt 0) {
            Write-Host ("CLEANUP FAIL: reception=$rn extraIds=[{0}] missingIds=[{1}]" -f ($extra -join ','), ($missing -join ',')) -ForegroundColor Red
            $ok = $false
        }
    }

    # 3) Restore EPC tag_mode2 (+ updated when known)
    foreach ($epc in @($epcSnapshots.Keys)) {
        $snap = $epcSnapshots[$epc]
        if ($null -ne $snap.Updated) {
            $n = Invoke-SqlNonQuery -Sql @"
UPDATE [dbo].[ICタグ台帳]
SET [tag_mode2] = @mode2,
    [updated] = @updated
WHERE LTRIM(RTRIM([tag_id2])) = @epc
"@ -Parameters @{ '@mode2' = $snap.TagMode2; '@updated' = $snap.Updated; '@epc' = $epc }
        }
        else {
            $n = Invoke-SqlNonQuery -Sql @"
UPDATE [dbo].[ICタグ台帳]
SET [tag_mode2] = @mode2
WHERE LTRIM(RTRIM([tag_id2])) = @epc
"@ -Parameters @{ '@mode2' = $snap.TagMode2; '@epc' = $epc }
        }
        $after = Get-LedgerSnapshot -Epc $epc
        if ($null -eq $after -or $after.TagMode2 -ne $snap.TagMode2) {
            Write-Host ("RESTORE FAIL: epc=$epc expectedMode=[$($snap.TagMode2)] actual=[$($after.TagMode2)]") -ForegroundColor Red
            $ok = $false
        }
        else {
            Write-Host ("Restored epc=$epc mode2=[$($snap.TagMode2)] updatedRows=$n")
        }
    }

    # 4) Side tables unchanged（納品台帳 / 納品明細 / tag_table4）
    $daicho = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[納品台帳]")
    $meisai = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[納品明細]")
    $t4 = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[tag_table4]")
    if ($daicho -ne $sideCountsBefore.DeliveryLedger -or $meisai -ne $sideCountsBefore.DeliveryDetail -or $t4 -ne $sideCountsBefore.TagTable4) {
        Write-Host ("SIDE TABLE FAIL: daicho $daicho/$($sideCountsBefore.DeliveryLedger) meisai $meisai/$($sideCountsBefore.DeliveryDetail) t4 $t4/$($sideCountsBefore.TagTable4)") -ForegroundColor Red
        $ok = $false
    }

    # 5) No leftover temp triggers named for this test (safety)
    $trig = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM sys.triggers WHERE name LIKE N'trg_link_tags_staging_%'")
    if ($trig -ne 0) {
        Write-Host "TRIGGER FAIL: trg_link_tags_staging_* still exists count=$trig" -ForegroundColor Red
        $ok = $false
    }

    if ($ok) {
        Add-Result -Id 'CLEANUP' -Name 'restore+delete inserted only' -Verdict 'PASS' `
            -Expected 'pre-test state for EPCs and reception t3; side counts unchanged' `
            -Actual ("deletedT3=$deleted epcsRestored=$($epcSnapshots.Count)")
    }
    else {
        Add-Result -Id 'CLEANUP' -Name 'restore+delete inserted only' -Verdict 'FAIL' `
            -Expected 'pre-test state restored' `
            -Actual ("deletedT3=$deleted; see CLEANUP FAIL lines")
    }
    $script:cleanupOk = $ok
    return $ok
}

# ----------------- MAIN -----------------
try {
    Write-Section "GATE: BaseUrl / hosts"
    Write-Host "BaseUrl=$BaseUrl"
    Write-Host "SqlServer=$SqlServer SqlDatabase=$SqlDatabase"
    Write-Host ("RequireRunDangerousA34=" + [bool]$RequireRunDangerousA34)

    Write-Section "GATE: GET /api/environment"
    $envResp = Invoke-ApiRequest -Method GET -Path '/api/environment'
    if ($envResp.StatusCode -ne 200) {
        Write-Error "REFUSED: /api/environment failed: $($envResp.Error) $($envResp.Raw)"
        exit 2
    }
    $readOnly = Get-JsonProperty $envResp.Body 'readOnly'
    $databaseKind = Get-JsonProperty $envResp.Body 'databaseKind'
    $environment = Get-JsonProperty $envResp.Body 'environment'
    Write-Host ("environment={0} databaseKind={1} readOnly={2}" -f $environment, $databaseKind, $readOnly)
    if ($readOnly -ne $false) { Write-Error "REFUSED: readOnly must be false. got=$readOnly"; exit 2 }
    if ("$databaseKind" -eq 'Production') { Write-Error "REFUSED: databaseKind must not be Production"; exit 2 }
    Write-Host "Gate PASSED" -ForegroundColor Green

    Write-Section "GATE: SQL DB"
    $dbName = [string](Invoke-SqlScalar -Sql "SELECT DB_NAME()")
    if ($dbName -ne 'OOMIYADB') { Write-Error "REFUSED: DB_NAME()='$dbName'"; exit 2 }

    Write-Section "GATE: required tables"
    $requiredTables = @(
        '納品台帳',
        '納品明細',
        'tag_table3',
        'tag_table4',
        'ICタグ台帳'
    )
    foreach ($tbl in $requiredTables) {
        $oid = Invoke-SqlScalar -Sql "SELECT OBJECT_ID(@n, N'U')" -Parameters @{ '@n' = "dbo.$tbl" }
        if ($null -eq $oid) {
            Write-Error "REFUSED: required table missing: [dbo].[$tbl]"
            exit 2
        }
        Write-Host ("OK table [dbo].[{0}] object_id={1}" -f $tbl, $oid)
    }
    Write-Host "Required tables PASSED" -ForegroundColor Green

    # Fingerprint: reception subjects must match expected roles
    $subjD = Get-ReceptionSubject -ReceptionNo $ReceptionDelivery
    $subjP = Get-ReceptionSubject -ReceptionNo $ReceptionPickup
    $subjE = Get-ReceptionSubject -ReceptionNo $ReceptionExchange
    Write-Host "ReceptionDelivery=$ReceptionDelivery subject=[$subjD]"
    Write-Host "ReceptionPickup=$ReceptionPickup subject=[$subjP]"
    Write-Host "ReceptionExchange=$ReceptionExchange subject=[$subjE]"
    if ($subjD -ne '<配達>' -and $subjD -ne '来店(納品)') {
        Write-Error "REFUSED: ReceptionDelivery subject must be <配達> or 来店(納品). got=[$subjD]"
        exit 2
    }
    if ($subjP -ne '引取' -and $subjP -ne '来店(返品)') {
        Write-Error "REFUSED: ReceptionPickup subject must be 引取 or 来店(返品). got=[$subjP]"
        exit 2
    }
    if ($subjE -ne '交換') {
        Write-Error "REFUSED: ReceptionExchange subject must be 交換. got=[$subjE]"
        exit 2
    }

    $allEpcs = @($EpcDelivery1, $EpcDelivery2, $EpcPickup1, $EpcPickup2, $EpcExchangeDelivery, $EpcExchangeReturn)
    Write-Section "SNAPSHOT before"
    foreach ($epc in $allEpcs) {
        $snap = Get-LedgerSnapshot -Epc $epc
        if ($null -eq $snap) { Write-Error "REFUSED: EPC not in ledger: $epc"; exit 2 }
        $epcSnapshots[$epc] = $snap
        Write-Host ("EPC={0} code={1} num={2} mode2=[{3}] updated={4}" -f $snap.Epc, $snap.ProductCode, $snap.Number, $snap.TagMode2, $snap.Updated)
    }
    foreach ($rn in @($ReceptionDelivery, $ReceptionPickup, $ReceptionExchange)) {
        $ids = Normalize-IntHashSet (Get-TagTable3Ids -ReceptionNo $rn)
        $receptionT3IdsBefore[$rn] = $ids
        Write-Host ("reception=$rn existing tag_table3 IDs count=$($ids.Count) => [" + ((@($ids) | Sort-Object) -join ',') + "]")
    }
    $sideCountsBefore = [pscustomobject]@{
        DeliveryLedger = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[納品台帳]")
        DeliveryDetail = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[納品明細]")
        TagTable4      = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[tag_table4]")
        TagTable3      = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[tag_table3]")
    }
    Write-Host ("sideCounts=" + ($sideCountsBefore | ConvertTo-Json -Compress))
    Write-Host ("  納品台帳={0} 納品明細={1} tag_table4={2} tag_table3={3}" -f `
        $sideCountsBefore.DeliveryLedger, $sideCountsBefore.DeliveryDetail, `
        $sideCountsBefore.TagTable4, $sideCountsBefore.TagTable3)

    if ($PreCheckOnly) {
        Write-Section "PRECHECK ONLY"
        Write-Host "PreCheckOnly=True: stopping before API POSTs." -ForegroundColor Green
        Add-Result -Id 'PRECHECK' -Name 'gates+tables+snapshot' -Verdict 'PASS' `
            -Expected 'env/tables/receptions/EPCs/counts OK' `
            -Actual ("daicho=$($sideCountsBefore.DeliveryLedger) meisai=$($sideCountsBefore.DeliveryDetail) t4=$($sideCountsBefore.TagTable4)")
        $script:cleanupOk = $true
    }
    else {

    # ========== A1 normal ==========
    Write-Section "A1-1 delivery normal"
    $bodyA11 = New-LinkBody -Items @(
        @{ epc = $EpcDelivery1; product_code = "$($epcSnapshots[$EpcDelivery1].ProductCode)" }
    )
    $rA11 = Post-LinkTags -ReceptionNo $ReceptionDelivery -JsonBody $bodyA11
    if ($rA11.StatusCode -eq 200) { Track-NewTagTable3Ids -ReceptionNo $ReceptionDelivery }
    Assert-StatusCode -Id 'A1-1-HTTP' -Name 'delivery HTTP' -Response $rA11 -ExpectedCodes @(200) | Out-Null
    Assert-LedgerAndT3 -Id 'A1-1-DB' -Name 'delivery DB' -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery1 `
        -ExpectMode2 '貸出中' -ExpectT3Mode '納品' -ExpectComplete 0 | Out-Null

    Write-Section "A1-2 pickup normal"
    $bodyA12 = New-LinkBody -Items @(
        @{ epc = $EpcPickup1; product_code = "$($epcSnapshots[$EpcPickup1].ProductCode)" }
    )
    $rA12 = Post-LinkTags -ReceptionNo $ReceptionPickup -JsonBody $bodyA12
    if ($rA12.StatusCode -eq 200) { Track-NewTagTable3Ids -ReceptionNo $ReceptionPickup }
    Assert-StatusCode -Id 'A1-2-HTTP' -Name 'pickup HTTP' -Response $rA12 -ExpectedCodes @(200) | Out-Null
    Assert-LedgerAndT3 -Id 'A1-2-DB' -Name 'pickup DB' -ReceptionNo $ReceptionPickup -Epc $EpcPickup1 `
        -ExpectMode2 '在庫' -ExpectT3Mode '返品' -ExpectComplete 1 | Out-Null

    Write-Section "A1-3 exchange delivery"
    $bodyA13 = New-LinkBody -LinkMode '交換納品' -Items @(
        @{ epc = $EpcExchangeDelivery; product_code = "$($epcSnapshots[$EpcExchangeDelivery].ProductCode)" }
    )
    $rA13 = Post-LinkTags -ReceptionNo $ReceptionExchange -JsonBody $bodyA13
    if ($rA13.StatusCode -eq 200) { Track-NewTagTable3Ids -ReceptionNo $ReceptionExchange }
    Assert-StatusCode -Id 'A1-3-HTTP' -Name 'exchange-delivery HTTP' -Response $rA13 -ExpectedCodes @(200) | Out-Null
    Assert-LedgerAndT3 -Id 'A1-3-DB' -Name 'exchange-delivery DB' -ReceptionNo $ReceptionExchange -Epc $EpcExchangeDelivery `
        -ExpectMode2 '貸出中' -ExpectT3Mode '交換納品' -ExpectComplete 0 | Out-Null

    Write-Section "A1-4 exchange return"
    $bodyA14 = New-LinkBody -LinkMode '交換返品' -Items @(
        @{ epc = $EpcExchangeReturn; product_code = "$($epcSnapshots[$EpcExchangeReturn].ProductCode)" }
    )
    $rA14 = Post-LinkTags -ReceptionNo $ReceptionExchange -JsonBody $bodyA14
    if ($rA14.StatusCode -eq 200) { Track-NewTagTable3Ids -ReceptionNo $ReceptionExchange }
    Assert-StatusCode -Id 'A1-4-HTTP' -Name 'exchange-return HTTP' -Response $rA14 -ExpectedCodes @(200) | Out-Null
    Assert-LedgerAndT3 -Id 'A1-4-DB' -Name 'exchange-return DB' -ReceptionNo $ReceptionExchange -Epc $EpcExchangeReturn `
        -ExpectMode2 '整備中' -ExpectT3Mode '交換返品' -ExpectComplete 1 | Out-Null

    Write-Section "A1-5 multi EPC delivery (EpcDelivery2)"
    $bodyA15 = New-LinkBody -Items @(
        @{ epc = $EpcDelivery2; product_code = "$($epcSnapshots[$EpcDelivery2].ProductCode)" }
    )
    $rA15 = Post-LinkTags -ReceptionNo $ReceptionDelivery -JsonBody $bodyA15
    if ($rA15.StatusCode -eq 200) { Track-NewTagTable3Ids -ReceptionNo $ReceptionDelivery }
    Assert-StatusCode -Id 'A1-5-HTTP' -Name 'delivery2 HTTP' -Response $rA15 -ExpectedCodes @(200) | Out-Null
    Assert-LedgerAndT3 -Id 'A1-5-DB' -Name 'delivery2 DB' -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery2 `
        -ExpectMode2 '貸出中' -ExpectT3Mode '納品' -ExpectComplete 0 | Out-Null

    # ========== A2 errors ==========
    Write-Section "A2 validation / not found"
    $snapBeforeA2 = Get-LedgerSnapshot -Epc $EpcDelivery1
    $t3BeforeA2 = (Get-TagTable3Rows -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery1).Rows.Count

    $rA21 = Post-LinkTags -ReceptionNo $ReceptionDelivery -JsonBody '{"user_id":"51","items":[]}'
    Assert-StatusCode -Id 'A2-1' -Name 'items empty' -Response $rA21 -ExpectedCodes @(400) | Out-Null

    $rA22 = Invoke-ApiRequest -Method POST -Path '/api/reception-slips/NOT_A_NUMBER/link-tags' -Body (New-LinkBody -Items @(@{ epc = $EpcDelivery1 }))
    Assert-StatusCode -Id 'A2-2' -Name 'receptionNo non-int' -Response $rA22 -ExpectedCodes @(400) | Out-Null

    $rA23 = Post-LinkTags -ReceptionNo 999999999 -JsonBody (New-LinkBody -Items @(@{ epc = $EpcDelivery1 }))
    Assert-StatusCode -Id 'A2-3' -Name 'reception missing' -Response $rA23 -ExpectedCodes @(404) | Out-Null

    $rA24 = Post-LinkTags -ReceptionNo $ReceptionExchange -JsonBody (New-LinkBody -Items @(@{ epc = $EpcExchangeDelivery }))
    Assert-StatusCode -Id 'A2-4' -Name 'exchange without link_mode' -Response $rA24 -ExpectedCodes @(400) | Out-Null

    $rA25 = Post-LinkTags -ReceptionNo $ReceptionExchange -JsonBody (New-LinkBody -LinkMode '不正' -Items @(@{ epc = $EpcExchangeDelivery }))
    Assert-StatusCode -Id 'A2-5' -Name 'exchange bad link_mode' -Response $rA25 -ExpectedCodes @(400) | Out-Null

    $snapAfterA2 = Get-LedgerSnapshot -Epc $EpcDelivery1
    $t3AfterA2 = (Get-TagTable3Rows -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery1).Rows.Count
    if ($snapAfterA2.TagMode2 -eq $snapBeforeA2.TagMode2 -and $t3AfterA2 -eq $t3BeforeA2) {
        Add-Result -Id 'A2-DB' -Name 'error paths left delivery1 unchanged' -Verdict 'PASS' `
            -Expected 'mode/t3 unchanged' -Actual ("mode=$($snapAfterA2.TagMode2) t3Rows=$t3AfterA2")
    }
    else {
        Add-Result -Id 'A2-DB' -Name 'error paths left delivery1 unchanged' -Verdict 'FAIL' `
            -Expected 'mode/t3 unchanged' -Actual ("beforeMode=$($snapBeforeA2.TagMode2) afterMode=$($snapAfterA2.TagMode2) t3 $t3BeforeA2->$t3AfterA2")
    }

    # ========== A2-6 rollback: valid + missing EPC ==========
    Write-Section "A2-6 rollback mixed missing EPC"
    $modeBeforeRb = (Get-LedgerSnapshot -Epc $EpcPickup2).TagMode2
    $t3BeforeRb = (Get-TagTable3Rows -ReceptionNo $ReceptionPickup -Epc $EpcPickup2).Rows.Count
    $bodyRb = New-LinkBody -Items @(
        @{ epc = $EpcPickup2; product_code = "$($epcSnapshots[$EpcPickup2].ProductCode)" },
        @{ epc = $FakeMissingEpc; product_code = '1' }
    )
    $rRb = Post-LinkTags -ReceptionNo $ReceptionPickup -JsonBody $bodyRb
    Assert-StatusCode -Id 'A2-6-HTTP' -Name 'mixed missing => 404' -Response $rRb -ExpectedCodes @(404) | Out-Null
    Track-NewTagTable3Ids -ReceptionNo $ReceptionPickup  # should add nothing if rolled back
    $modeAfterRb = (Get-LedgerSnapshot -Epc $EpcPickup2).TagMode2
    $t3AfterRb = (Get-TagTable3Rows -ReceptionNo $ReceptionPickup -Epc $EpcPickup2).Rows.Count
    if ($modeAfterRb -eq $modeBeforeRb -and $t3AfterRb -eq $t3BeforeRb) {
        Add-Result -Id 'A2-6-DB' -Name 'rollback no partial update' -Verdict 'PASS' `
            -Expected 'pickup2 unchanged' -Actual ("mode=$modeAfterRb t3Rows=$t3AfterRb")
    }
    else {
        Add-Result -Id 'A2-6-DB' -Name 'rollback no partial update' -Verdict 'FAIL' `
            -Expected 'pickup2 unchanged' -Actual ("mode $modeBeforeRb->$modeAfterRb t3 $t3BeforeRb->$t3AfterRb")
    }

    # ========== A3 duplicate / resend ==========
    Write-Section "A3-1 same-request duplicate EPC"
    $t3BeforeDup = (Get-TagTable3Rows -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery1).Rows.Count
    $bodyDup = New-LinkBody -Items @(
        @{ epc = $EpcDelivery1; product_code = "$($epcSnapshots[$EpcDelivery1].ProductCode)" },
        @{ epc = $EpcDelivery1; product_code = "$($epcSnapshots[$EpcDelivery1].ProductCode)" }
    )
    $rDup = Post-LinkTags -ReceptionNo $ReceptionDelivery -JsonBody $bodyDup
    if ($rDup.StatusCode -eq 200) { Track-NewTagTable3Ids -ReceptionNo $ReceptionDelivery }
    $t3AfterDup = (Get-TagTable3Rows -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery1).Rows.Count
    $linked = Get-JsonProperty $rDup.Body 'linked'
    if ($rDup.StatusCode -eq 200 -and $t3AfterDup -eq 1 -and [int]$linked -eq 1) {
        Add-Result -Id 'A3-1' -Name 'in-request duplicate EPC' -Verdict 'PASS' `
            -Expected '200 linked=1 t3Rows=1' -Actual ("HTTP=$($rDup.StatusCode) linked=$linked t3Rows=$t3AfterDup")
    }
    else {
        Add-Result -Id 'A3-1' -Name 'in-request duplicate EPC' -Verdict 'FAIL' `
            -Expected '200 linked=1 t3Rows=1' -Actual ("HTTP=$($rDup.StatusCode) linked=$linked t3Rows=$t3AfterDup before=$t3BeforeDup")
    }

    Write-Section "A3-2 resend delivery (complete=0 replace)"
    $idBefore = @((Get-TagTable3Rows -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery1).Rows | ForEach-Object { [int]$_['ID'] })
    $rResend = Post-LinkTags -ReceptionNo $ReceptionDelivery -JsonBody (New-LinkBody -Items @(
        @{ epc = $EpcDelivery1; product_code = "$($epcSnapshots[$EpcDelivery1].ProductCode)" }
    ))
    if ($rResend.StatusCode -eq 200) { Track-NewTagTable3Ids -ReceptionNo $ReceptionDelivery }
    $rowsResend = Get-TagTable3Rows -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery1
    $idAfter = @($rowsResend.Rows | ForEach-Object { [int]$_['ID'] })
    if ($rResend.StatusCode -eq 200 -and $rowsResend.Rows.Count -eq 1) {
        Add-Result -Id 'A3-2' -Name 'resend delivery single row' -Verdict 'PASS' `
            -Expected '1 row after resend' -Actual ("rows=1 idsBefore=[$($idBefore -join ',')] idsAfter=[$($idAfter -join ',')]")
    }
    else {
        Add-Result -Id 'A3-2' -Name 'resend delivery single row' -Verdict 'FAIL' `
            -Expected '1 row after resend' -Actual ("HTTP=$($rResend.StatusCode) rows=$($rowsResend.Rows.Count)")
    }

    Write-Section "A3-3 resend pickup (complete=1 => idempotent skip)"
    $idBeforeP = @((Get-TagTable3Rows -ReceptionNo $ReceptionPickup -Epc $EpcPickup1).Rows | ForEach-Object { [int]$_['ID'] })
    $modeBeforeP = (Get-LedgerSnapshot -Epc $EpcPickup1).TagMode2
    $rResendP = Post-LinkTags -ReceptionNo $ReceptionPickup -JsonBody (New-LinkBody -Items @(
        @{ epc = $EpcPickup1; product_code = "$($epcSnapshots[$EpcPickup1].ProductCode)" }
    ))
    if ($rResendP.StatusCode -eq 200) { Track-NewTagTable3Ids -ReceptionNo $ReceptionPickup }
    $rowsP = Get-TagTable3Rows -ReceptionNo $ReceptionPickup -Epc $EpcPickup1
    $idAfterP = @($rowsP.Rows | ForEach-Object { [int]$_['ID'] })
    $modeAfterP = (Get-LedgerSnapshot -Epc $EpcPickup1).TagMode2
    $linkedP = Get-JsonProperty $rResendP.Body 'linked'
    $warnP = Get-JsonProperty $rResendP.Body 'warnings'
    $warnTextP = if ($warnP) { (@($warnP) -join ';') } else { '' }
    if ($rResendP.StatusCode -eq 200 `
            -and $rowsP.Rows.Count -eq 1 `
            -and [int]$rowsP.Rows[0]['complete'] -eq 1 `
            -and [int]$linkedP -eq 0 `
            -and $modeAfterP -eq $modeBeforeP `
            -and ($idBeforeP -join ',') -eq ($idAfterP -join ',') `
            -and $warnTextP -match '処理済み') {
        Add-Result -Id 'A3-3' -Name 'resend pickup idempotent skip' -Verdict 'PASS' `
            -Expected 'HTTP200 linked=0 rows=1 same id; ledger unchanged' `
            -Actual ("HTTP=$($rResendP.StatusCode) linked=$linkedP rows=1 id=$($idAfterP -join ',') warn=$warnTextP")
    }
    else {
        Add-Result -Id 'A3-3' -Name 'resend pickup idempotent skip' -Verdict 'FAIL' `
            -Expected 'HTTP200 linked=0 rows=1 same id; ledger unchanged' `
            -Actual ("HTTP=$($rResendP.StatusCode) linked=$linkedP rows=$($rowsP.Rows.Count) idsBefore=[$($idBeforeP -join ',')] idsAfter=[$($idAfterP -join ',')] mode $modeBeforeP->$modeAfterP warn=$warnTextP")
    }

    # A3-4: mark delivery row complete=1 then repost (OFF unless -RequireRunDangerousA34)
    if ($RequireRunDangerousA34) {
        Write-Section "A3-4: complete=1 then repost delivery (expect no duplicate)"
        $modeBeforeD = (Get-LedgerSnapshot -Epc $EpcDelivery1).TagMode2
        $n = Invoke-SqlNonQuery -Sql @"
UPDATE [dbo].[tag_table3]
SET [complete] = 1
WHERE [受付番号]=@n AND LTRIM(RTRIM(tag_id2))=@epc AND ISNULL(complete,0)=0
"@ -Parameters @{ '@n' = $ReceptionDelivery; '@epc' = $EpcDelivery1 }
        Write-Host "Forced complete=1 on delivery1 rowsAffected=$n"
        $rowsBeforeD = Get-TagTable3Rows -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery1
        $beforeDanger = $rowsBeforeD.Rows.Count
        $idsBeforeD = @($rowsBeforeD.Rows | ForEach-Object { [int]$_['ID'] })
        $rDanger = Post-LinkTags -ReceptionNo $ReceptionDelivery -JsonBody (New-LinkBody -Items @(
            @{ epc = $EpcDelivery1; product_code = "$($epcSnapshots[$EpcDelivery1].ProductCode)" }
        ))
        if ($rDanger.StatusCode -eq 200) { Track-NewTagTable3Ids -ReceptionNo $ReceptionDelivery }
        $rowsAfterD = Get-TagTable3Rows -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery1
        $afterDanger = $rowsAfterD.Rows.Count
        $idsAfterD = @($rowsAfterD.Rows | ForEach-Object { [int]$_['ID'] })
        $modeAfterD = (Get-LedgerSnapshot -Epc $EpcDelivery1).TagMode2
        $linkedD = Get-JsonProperty $rDanger.Body 'linked'
        $warnD = Get-JsonProperty $rDanger.Body 'warnings'
        $warnTextD = if ($warnD) { (@($warnD) -join ';') } else { '' }
        if ($rDanger.StatusCode -eq 200 `
                -and $afterDanger -eq 1 `
                -and $beforeDanger -eq 1 `
                -and [int]$linkedD -eq 0 `
                -and $modeAfterD -eq $modeBeforeD `
                -and ($idsBeforeD -join ',') -eq ($idsAfterD -join ',') `
                -and $warnTextD -match '処理済み') {
            Add-Result -Id 'A3-4' -Name 'repost after complete=1 no duplicate' -Verdict 'PASS' `
                -Expected 'HTTP200 linked=0 rows=1 same id; no insert' `
                -Actual ("HTTP=$($rDanger.StatusCode) linked=$linkedD rows=$afterDanger id=$($idsAfterD -join ',') forced=$n warn=$warnTextD")
        }
        else {
            Add-Result -Id 'A3-4' -Name 'repost after complete=1 no duplicate' -Verdict 'FAIL' `
                -Expected 'HTTP200 linked=0 rows=1 same id; no insert' `
                -Actual ("HTTP=$($rDanger.StatusCode) linked=$linkedD rowsBefore=$beforeDanger rowsAfter=$afterDanger ids=[$($idsAfterD -join ',')] mode $modeBeforeD->$modeAfterD forced=$n warn=$warnTextD")
        }
    }
    else {
        Add-Result -Id 'A3-4' -Name 'dangerous skipped' -Verdict 'OBSERVE' `
            -Expected 'not run without -RequireRunDangerousA34' -Actual 'SKIPPED'
    }

    # ========== Parallel ==========
    if (-not $SkipParallel) {
        Write-Section "A3-5 parallel same delivery EPC"
        $beforePar = (Get-TagTable3Rows -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery2).Rows.Count
        $parBody = New-LinkBody -Items @(
            @{ epc = $EpcDelivery2; product_code = "$($epcSnapshots[$EpcDelivery2].ProductCode)" }
        )
        $jobA = Start-Job -ScriptBlock {
            param($Url, $Rn, $Body)
            try {
                $r = Invoke-WebRequest -Uri "$Url/api/reception-slips/$Rn/link-tags" -Method POST -ContentType 'application/json; charset=utf-8' `
                    -Body ([Text.Encoding]::UTF8.GetBytes($Body)) -TimeoutSec 60 -UseBasicParsing
                return @{ Code = [int]$r.StatusCode; Body = $r.Content }
            } catch {
                $code = $null
                if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
                return @{ Code = $code; Body = $_.Exception.Message }
            }
        } -ArgumentList $BaseUrl, $ReceptionDelivery, $parBody
        $jobB = Start-Job -ScriptBlock {
            param($Url, $Rn, $Body)
            try {
                $r = Invoke-WebRequest -Uri "$Url/api/reception-slips/$Rn/link-tags" -Method POST -ContentType 'application/json; charset=utf-8' `
                    -Body ([Text.Encoding]::UTF8.GetBytes($Body)) -TimeoutSec 60 -UseBasicParsing
                return @{ Code = [int]$r.StatusCode; Body = $r.Content }
            } catch {
                $code = $null
                if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
                return @{ Code = $code; Body = $_.Exception.Message }
            }
        } -ArgumentList $BaseUrl, $ReceptionDelivery, $parBody
        $null = Wait-Job $jobA, $jobB -Timeout 90
        $outA = Receive-Job $jobA; $outB = Receive-Job $jobB
        Remove-Job $jobA, $jobB -Force -ErrorAction SilentlyContinue
        Track-NewTagTable3Ids -ReceptionNo $ReceptionDelivery
        $afterPar = (Get-TagTable3Rows -ReceptionNo $ReceptionDelivery -Epc $EpcDelivery2).Rows.Count
        Add-Result -Id 'A3-5-ORDER' -Name 'parallel status order' -Verdict 'OBSERVE' `
            -Expected 'order not judged' -Actual ("a=$($outA.Code) b=$($outB.Code) rows=$afterPar")
        if ($afterPar -eq 1) {
            Add-Result -Id 'A3-5' -Name 'parallel no duplicate t3' -Verdict 'PASS' `
                -Expected 'exactly 1 tag_table3 row' -Actual "before=$beforePar after=$afterPar"
        }
        else {
            Add-Result -Id 'A3-5' -Name 'parallel no duplicate t3' -Verdict 'FAIL' `
                -Expected 'exactly 1 tag_table3 row' -Actual "before=$beforePar after=$afterPar"
        }
    }
    else {
        Add-Result -Id 'A3-5' -Name 'parallel skipped' -Verdict 'OBSERVE' -Expected 'skipped' -Actual 'SkipParallel'
    }

    # ========== Integrity side tables mid-run (should still equal before for 納品*) ==========
    Write-Section "A4 side-table integrity (no 納品台帳/明細/tag_table4 writes)"
    $daichoNow = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[納品台帳]")
    $meisaiNow = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[納品明細]")
    $t4Now = [int](Invoke-SqlScalar -Sql "SELECT COUNT(1) FROM [dbo].[tag_table4]")
    if ($daichoNow -eq $sideCountsBefore.DeliveryLedger -and $meisaiNow -eq $sideCountsBefore.DeliveryDetail -and $t4Now -eq $sideCountsBefore.TagTable4) {
        Add-Result -Id 'A4-1' -Name '納品台帳/明細/tag_table4 unchanged' -Verdict 'PASS' `
            -Expected 'counts unchanged' -Actual ("daicho=$daichoNow meisai=$meisaiNow t4=$t4Now")
    }
    else {
        Add-Result -Id 'A4-1' -Name '納品台帳/明細/tag_table4 unchanged' -Verdict 'FAIL' `
            -Expected 'counts unchanged' -Actual ("daicho=$daichoNow/$($sideCountsBefore.DeliveryLedger) meisai=$meisaiNow/$($sideCountsBefore.DeliveryDetail) t4=$t4Now/$($sideCountsBefore.TagTable4)")
    }

    } # end -not PreCheckOnly
}
catch {
    Write-Host ("TEST ERROR: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host ("At: " + $_.InvocationInfo.PositionMessage) -ForegroundColor DarkYellow
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkYellow }
    Add-Result -Id 'SCRIPT' -Name 'uncaught error' -Verdict 'FAIL' -Expected 'no exception' -Actual $_.Exception.Message
}
finally {
    try { Invoke-CleanupAndRestore | Out-Null }
    catch {
        $script:cleanupOk = $false
        Add-Result -Id 'CLEANUP' -Name 'restore+delete inserted only' -Verdict 'FAIL' `
            -Expected 'cleanup succeeds' -Actual $_.Exception.Message
    }
}

Write-Section "SUMMARY"
$pass = @($results | Where-Object { $_.Verdict -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.Verdict -eq 'FAIL' }).Count
$obs  = @($results | Where-Object { $_.Verdict -eq 'OBSERVE' }).Count
Write-Host ("PASS={0} FAIL={1} OBSERVE={2} cleanupOk={3}" -f $pass, $fail, $obs, $cleanupOk)
$results | ForEach-Object {
    Write-Host ("{0,-12} {1,-8} {2,-40} {3}" -f $_.Id, $_.Verdict, $_.Name, $_.Actual)
}

$summaryPath = Join-Path $PSScriptRoot 'test-link-tags-staging-last-result.json'
$payload = [pscustomobject]@{
    ranAt = (Get-Date).ToString('o')
    baseUrl = $BaseUrl
    requireRunDangerousA34 = [bool]$RequireRunDangerousA34
    receptions = @{
        delivery = @{ no = $ReceptionDelivery; subject = $subjD }
        pickup   = @{ no = $ReceptionPickup; subject = $subjP }
        exchange = @{ no = $ReceptionExchange; subject = $subjE }
    }
    epcs = $allEpcs
    insertedTagTable3Ids = @($insertedTagTable3Ids)
    cleanupOk = $cleanupOk
    pass = $pass; fail = $fail; observe = $obs
    results = $results
}
$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host "Wrote $summaryPath"

if (-not $cleanupOk) { exit 3 }
if ($fail -gt 0) { exit 1 }
exit 0
