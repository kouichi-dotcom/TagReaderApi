using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using TagReaderApi.Models;

namespace TagReaderApi.Controllers;

/// <summary>
/// 受付台帳API。絞り込み: 受付日時=当日、転記済み=0、処理者=担当者コード（または未定モードで処理者未入力）。
/// 受付明細は受付番号で紐付け、商品名・台数・単位名を返す。
/// </summary>
[ApiController]
[Route("api/reception-slips")]
public class ReceptionSlipsController : ControllerBase
{
    private readonly string _connectionString;
    private readonly bool _readOnly;
    private readonly ILogger<ReceptionSlipsController> _logger;

    public ReceptionSlipsController(IConfiguration configuration, ILogger<ReceptionSlipsController> logger)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
        _readOnly = configuration.GetValue("Database:ReadOnly", false);
        _logger = logger;
    }

    /// <summary>
    /// 受付伝票一覧を取得。
    /// 絞り込み: 受付日時が指定日（省略時は当日）、転記済み=0、処理者=担当者コード。
    /// unassignedOnly=true のときは「配達担当者が未定の伝票」のみ（処理者未入力）。
    /// </summary>
    /// <param name="date">受付日（yyyy-MM-dd）。省略時は当日</param>
    /// <param name="assigneeCode">担当者コード（配達担当）。unassignedOnly=false のとき処理者と一致する伝票を表示</param>
    /// <param name="unassignedOnly">true: 配達担当者未定（処理者未入力）の伝票のみ。このとき assigneeCode は不要</param>
    /// <param name="random">true: ランダム取得（テスト用）。このとき date/assigneeCode/unassignedOnly は無視</param>
    /// <param name="subjects">用件で絞り込み（カンマ区切り）。例: 来店(納品),来店(返品)。assigneeCode と併用可</param>
    /// <param name="limit">取得件数（1〜50）。省略時 10</param>
    /// <param name="offset">先頭からスキップする件数。省略時 0。random=true のときは無視</param>
    [HttpGet]
    [ProducesResponseType(typeof(IEnumerable<ReceptionSlipDto>), StatusCodes.Status200OK)]
    public async Task<IActionResult> Get(
        [FromQuery] DateTime? date,
        [FromQuery] string? assigneeCode,
        [FromQuery] bool unassignedOnly = false,
        [FromQuery] bool random = false,
        [FromQuery] string? subjects = null,
        [FromQuery] int limit = 10,
        [FromQuery] int offset = 0,
        CancellationToken cancellationToken = default)
    {
        var targetDate = date?.Date ?? DateTime.Today;
        var subjectList = subjects?
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(s => !string.IsNullOrWhiteSpace(s))
            .Select(s => s!.Trim())
            .Distinct()
            .ToList() ?? new List<string>();
        var take = Math.Clamp(limit, 1, 50);
        var skip = Math.Max(0, offset);

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        string whereClause;
        string orderClause;
        string pagingClause;
        if (random)
        {
            // ランダム取得（テスト用）: 異常日時のみ除外。offset は無視
            var minValidDate = new DateTime(1900, 1, 1);
            var maxValidDate = DateTime.Today.AddDays(1);
            whereClause = $@"WHERE r.[受付日時] IS NOT NULL
                AND r.[受付日時] >= '{minValidDate:yyyy-MM-dd}'
                AND r.[受付日時] < '{maxValidDate:yyyy-MM-dd}'";
            orderClause = "ORDER BY NEWID()";
            pagingClause = "TOP (@limit)";
        }
        else
        {
            var whereConditions = new List<string>();
            var maxValidDate = DateTime.Today.AddDays(1);
            var minValidDate = new DateTime(1900, 1, 1);
            whereConditions.Add("r.[受付日時] IS NOT NULL");
            whereConditions.Add($"r.[受付日時] >= '{minValidDate:yyyy-MM-dd}'");
            whereConditions.Add($"r.[受付日時] < '{maxValidDate:yyyy-MM-dd}'");
            whereConditions.Add("ISNULL(r.[転記済], 0) = 0");
            // 用件・担当者は併用可。date 未指定時は全期間から最新順（ページング）
            if (subjectList.Count > 0)
            {
                var subjectCondition = subjectList.Count == 1
                    ? $"p.[用件] = @subject0"
                    : "(" + string.Join(" OR ", subjectList.Select((_, i) => $"p.[用件] = @subject{i}")) + ")";
                whereConditions.Add(subjectCondition);
            }
            if (date.HasValue)
                whereConditions.Add("CAST(r.[受付日時] AS DATE) = @targetDate");
            if (!unassignedOnly && !string.IsNullOrWhiteSpace(assigneeCode))
                whereConditions.Add("r.[処理者] = CAST(@assigneeCode AS smallint)");
            else if (unassignedOnly)
                whereConditions.Add("r.[処理者] IS NULL");
            whereClause = "WHERE " + string.Join(" AND ", whereConditions);
            orderClause = "ORDER BY r.[受付日時] DESC, r.[受付番号] DESC";
            pagingClause = string.Empty;
        }

        var slipSql = random
            ? $@"
            SELECT {pagingClause}
                r.[受付番号], 
                ISNULL(p.[用件], '') AS [用件],
                ISNULL(c.[顧客名], ISNULL(r.[顧客名（その他）], 'その他')) AS CustomerName,
                r.[顧客名（その他）] AS [顧客名その他],
                ISNULL(s.[現場名], ISNULL(r.[現場名（その他）], 'その他')) AS SiteName,
                r.[現場名（その他）] AS [現場名その他],
                r.[期日], d.[期限] AS DeadlineName, r.[期限2] AS [期限２], r.[メモ],
                r.[受付日時], r.[処理者],
                h.[担当者氏名] AS HandlerName,
                s.[緯度経度] AS LatLng
            FROM [dbo].[受付台帳] r
            LEFT JOIN [dbo].[顧客台帳] c ON c.[顧客コード] = r.[顧客コード]
            LEFT JOIN [dbo].[現場台帳] s ON s.[現場ｺｰﾄﾞ] = r.[現場コード]
            LEFT JOIN [dbo].[期限台帳] d ON d.[期限コード] = r.[期限コード]
            LEFT JOIN [dbo].[用件台帳] p ON p.[用件コード] = r.[用件コード]
            LEFT JOIN [dbo].[担当者台帳] h ON h.[担当者コード] = r.[処理者]
            {whereClause}
            {orderClause}"
            : $@"
            SELECT
                r.[受付番号], 
                ISNULL(p.[用件], '') AS [用件],
                ISNULL(c.[顧客名], ISNULL(r.[顧客名（その他）], 'その他')) AS CustomerName,
                r.[顧客名（その他）] AS [顧客名その他],
                ISNULL(s.[現場名], ISNULL(r.[現場名（その他）], 'その他')) AS SiteName,
                r.[現場名（その他）] AS [現場名その他],
                r.[期日], d.[期限] AS DeadlineName, r.[期限2] AS [期限２], r.[メモ],
                r.[受付日時], r.[処理者],
                h.[担当者氏名] AS HandlerName,
                s.[緯度経度] AS LatLng
            FROM [dbo].[受付台帳] r
            LEFT JOIN [dbo].[顧客台帳] c ON c.[顧客コード] = r.[顧客コード]
            LEFT JOIN [dbo].[現場台帳] s ON s.[現場ｺｰﾄﾞ] = r.[現場コード]
            LEFT JOIN [dbo].[期限台帳] d ON d.[期限コード] = r.[期限コード]
            LEFT JOIN [dbo].[用件台帳] p ON p.[用件コード] = r.[用件コード]
            LEFT JOIN [dbo].[担当者台帳] h ON h.[担当者コード] = r.[処理者]
            {whereClause}
            {orderClause}
            OFFSET @offset ROWS FETCH NEXT @limit ROWS ONLY";

        await using var cmdSlip = new SqlCommand(slipSql, connection);
        cmdSlip.Parameters.AddWithValue("@limit", take);
        if (!random)
        {
            cmdSlip.Parameters.AddWithValue("@offset", skip);
            for (var i = 0; i < subjectList.Count; i++)
                cmdSlip.Parameters.AddWithValue($"@subject{i}", subjectList[i]);
            if (date.HasValue)
                cmdSlip.Parameters.AddWithValue("@targetDate", targetDate);
            if (!unassignedOnly && !string.IsNullOrWhiteSpace(assigneeCode) && short.TryParse(assigneeCode, out var assigneeCodeNum))
                cmdSlip.Parameters.AddWithValue("@assigneeCode", assigneeCodeNum);
        }

        var slips = new List<ReceptionSlipDto>();
        await using (var reader = await cmdSlip.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                slips.Add(new ReceptionSlipDto
                {
                    // 受付番号は int 型なので GetInt32() で取得して文字列に変換
                    ReceptionNo = reader.IsDBNull(0) ? string.Empty : reader.GetInt32(0).ToString(),
                    Subject = reader.IsDBNull(1) ? string.Empty : reader.GetString(1),
                    CustomerName = reader.IsDBNull(2) ? string.Empty : reader.GetString(2),
                    CustomerNameOther = reader.IsDBNull(3) ? null : reader.GetString(3),
                    SiteName = reader.IsDBNull(4) ? string.Empty : reader.GetString(4),
                    SiteNameOther = reader.IsDBNull(5) ? null : reader.GetString(5),
                    DueDate = reader.IsDBNull(6) ? null : reader.GetDateTime(6),
                    DeadlineName = reader.IsDBNull(7) ? null : reader.GetString(7),
                    Deadline2 = reader.IsDBNull(8) ? null : reader.GetString(8),
                    Memo = reader.IsDBNull(9) ? null : reader.GetString(9),
                    ReceptionAt = reader.IsDBNull(10) ? null : reader.GetDateTime(10),
                    // 処理者は smallint 型なので GetInt16() で取得して文字列に変換
                    HandlerCode = reader.IsDBNull(11) ? null : reader.GetInt16(11).ToString(),
                    HandlerName = reader.IsDBNull(12) ? null : (string.IsNullOrWhiteSpace(reader.GetString(12)) ? null : reader.GetString(12).Trim()),
                    LatLng = reader.IsDBNull(13) ? null : (string.IsNullOrWhiteSpace(reader.GetString(13)) ? null : reader.GetString(13).Trim())
                });
            }
        }

        if (slips.Count == 0)
            return Ok(slips);

        // 受付明細を一括取得（受付番号 IN (...)
        var receptionNos = slips.Select(x => x.ReceptionNo).Distinct().ToList();
        var detailByReceptionNo = new Dictionary<string, List<ReceptionDetailItemDto>>(StringComparer.OrdinalIgnoreCase);
        foreach (var no in receptionNos)
            detailByReceptionNo[no] = new List<ReceptionDetailItemDto>();

        // プレースホルダーを組み立て（IN 句は最大 2100 までなので分割しない簡易実装）
        var inParams = string.Join(", ", receptionNos.Select((_, i) => $"@n{i}"));
        var detailSql = $@"
            SELECT m.[受付番号], m.[商品コード], p.[商品名], m.[台数], u.[単位] AS [単位名]
            FROM [dbo].[受付明細] m
            LEFT JOIN [dbo].[商品台帳] p ON p.[商品コード] = m.[商品コード]
            LEFT JOIN [dbo].[単位台帳] u ON u.[単位コード] = m.[単位コード]
            WHERE m.[受付番号] IN ({inParams})";

        await using var cmdDetail = new SqlCommand(detailSql, connection);
        for (var i = 0; i < receptionNos.Count; i++)
        {
            // 受付番号は int 型なので、文字列から数値に変換
            if (int.TryParse(receptionNos[i], out var receptionNoInt))
                cmdDetail.Parameters.AddWithValue($"@n{i}", receptionNoInt);
            else
                cmdDetail.Parameters.AddWithValue($"@n{i}", DBNull.Value);
        }

        await using (var reader = await cmdDetail.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                // 受付番号は int 型なので GetInt32() で取得して文字列に変換
                var no = reader.IsDBNull(0) ? string.Empty : reader.GetInt32(0).ToString();
                if (!detailByReceptionNo.TryGetValue(no, out var list))
                    continue;
                list.Add(new ReceptionDetailItemDto
                {
                    ProductCode = reader.IsDBNull(1) ? null : reader.GetInt32(1),
                    ProductName = reader.IsDBNull(2) ? string.Empty : reader.GetString(2),
                    // 台数は real 型（float）なので GetFloat() で取得して decimal に変換
                    Quantity = reader.IsDBNull(3) ? null : (decimal?)reader.GetFloat(3),
                    UnitName = reader.IsDBNull(4) ? string.Empty : reader.GetString(4)
                });
            }
        }

        foreach (var slip in slips)
        {
            if (detailByReceptionNo.TryGetValue(slip.ReceptionNo, out var details))
                slip.Details = details;
        }

        return Ok(slips);
    }

    /// <summary>
    /// 受付伝票にタグを紐付けて DB に記録する。
    /// 用件「引取」「来店(返品)」: tag_mode2=在庫 / tag_mode=返品 / complete=1。
    /// 用件「交換」+ link_mode=交換納品: tag_mode2=貸出中 / tag_mode=交換納品 / complete=0。
    /// 用件「交換」+ link_mode=交換返品: tag_mode2=整備中 / tag_mode=交換返品 / complete=1。
    /// それ以外（&lt;配達&gt;・来店(納品) 等）: tag_mode2=貸出中 / tag_mode=納品 / complete=0。
    /// ※「交換（配達）」「交換（引取）」は交換ではなく配達モード扱い。
    /// </summary>
    [HttpPost("{receptionNo}/link-tags")]
    [ProducesResponseType(typeof(ReceptionSlipLinkTagsResponseDto), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<IActionResult> LinkTags(
        string receptionNo,
        [FromBody] ReceptionSlipLinkTagsRequestDto? body,
        CancellationToken cancellationToken = default)
    {
        if (_readOnly)
            return Conflict(new { message = "読み取り専用 DB のため紐付け送信できません。" });

        if (string.IsNullOrWhiteSpace(receptionNo) || !int.TryParse(receptionNo.Trim(), out var receptionNoInt))
            return BadRequest(new { message = "受付番号が不正です。", receptionNo });

        if (body?.Items == null || body.Items.Count == 0)
            return BadRequest(new { message = "items に 1 件以上のタグを指定してください。" });

        var items = new List<(string Epc, string? ProductCode)>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in body.Items)
        {
            var epc = item.Epc?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(epc))
                return BadRequest(new { message = "items[].epc は必須です。" });
            if (!seen.Add(epc))
                continue; // 同一リクエスト内の重複 EPC は無視
            items.Add((epc, string.IsNullOrWhiteSpace(item.ProductCode) ? null : item.ProductCode.Trim()));
        }

        int? sCode = null;
        if (!string.IsNullOrWhiteSpace(body.UserId) && int.TryParse(body.UserId.Trim(), out var parsedUserId))
            sCode = parsedUserId;

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);

        try
        {
            // 1. 受付番号の存在確認 + 用件取得
            const string existsSql = @"
                SELECT ISNULL(p.[用件], N'')
                FROM [dbo].[受付台帳] r
                LEFT JOIN [dbo].[用件台帳] p ON p.[用件コード] = r.[用件コード]
                WHERE r.[受付番号] = @receptionNo";
            string subject;
            await using (var existsCmd = new SqlCommand(existsSql, connection, transaction))
            {
                existsCmd.Parameters.Add(new SqlParameter("@receptionNo", System.Data.SqlDbType.Int) { Value = receptionNoInt });
                var scalar = await existsCmd.ExecuteScalarAsync(cancellationToken);
                if (scalar == null || scalar == DBNull.Value)
                {
                    await transaction.RollbackAsync(cancellationToken);
                    return NotFound(new { message = "該当する受付伝票が見つかりません。", receptionNo = receptionNoInt.ToString() });
                }
                subject = scalar.ToString()?.Trim() ?? string.Empty;
            }

            // 用件「交換」は完全一致のみ（交換（配達）/交換（引取）は含めない）
            // 引取 と 来店(返品) は同じ返品モード。配達(<配達>) と 来店(納品) は同じ納品モード。
            const string exchangeSubject = "交換";
            const string pickupSubject = "引取";
            const string visitReturnSubject = "来店(返品)";
            const string exchangeDeliveryMode = "交換納品";
            const string exchangeReturnMode = "交換返品";

            var isExchange = string.Equals(subject, exchangeSubject, StringComparison.Ordinal);
            string ledgerTagMode2;
            string table3TagMode;
            int table3Complete;
            string modeLabel;

            if (isExchange)
            {
                var linkMode = body.LinkMode?.Trim() ?? string.Empty;
                if (string.Equals(linkMode, exchangeDeliveryMode, StringComparison.Ordinal))
                {
                    ledgerTagMode2 = "貸出中";
                    table3TagMode = exchangeDeliveryMode;
                    table3Complete = 0;
                    modeLabel = "ExchangeDelivery";
                }
                else if (string.Equals(linkMode, exchangeReturnMode, StringComparison.Ordinal))
                {
                    ledgerTagMode2 = "整備中";
                    table3TagMode = exchangeReturnMode;
                    table3Complete = 1;
                    modeLabel = "ExchangeReturn";
                }
                else
                {
                    await transaction.RollbackAsync(cancellationToken);
                    return BadRequest(new
                    {
                        message = "用件が「交換」のときは link_mode に「交換納品」または「交換返品」を指定してください。",
                        receptionNo = receptionNoInt.ToString(),
                        link_mode = body.LinkMode,
                    });
                }
            }
            else
            {
                var isPickup =
                    string.Equals(subject, pickupSubject, StringComparison.Ordinal)
                    || string.Equals(subject, visitReturnSubject, StringComparison.Ordinal);
                ledgerTagMode2 = isPickup ? "在庫" : "貸出中";
                table3TagMode = isPickup ? "返品" : "納品";
                table3Complete = isPickup ? 1 : 0;
                modeLabel = isPickup ? "Pickup" : "Delivery";
            }

            _logger.LogInformation(
                "link-tags: reception={ReceptionNo} subject={Subject} mode={Mode} complete={Complete}",
                receptionNoInt, subject, modeLabel, table3Complete);

            // 受付明細の商品コード（警告用）
            var detailProductCodes = new HashSet<int>();
            const string detailSql = @"SELECT DISTINCT [商品コード] FROM [dbo].[受付明細] WHERE [受付番号] = @receptionNo AND [商品コード] IS NOT NULL";
            await using (var detailCmd = new SqlCommand(detailSql, connection, transaction))
            {
                detailCmd.Parameters.Add(new SqlParameter("@receptionNo", System.Data.SqlDbType.Int) { Value = receptionNoInt });
                await using var detailReader = await detailCmd.ExecuteReaderAsync(cancellationToken);
                while (await detailReader.ReadAsync(cancellationToken))
                {
                    if (!detailReader.IsDBNull(0))
                        detailProductCodes.Add(detailReader.GetInt32(0));
                }
            }

            var warnings = new List<string>();
            var missingEpcs = new List<string>();

            foreach (var (epc, productCode) in items)
            {
                // 2. EPC 存在確認 + 台帳の商品コード取得
                int? ledgerProductCode = null;
                const string ledgerSql = @"
                    SELECT [商品ｺｰﾄﾞ]
                    FROM [dbo].[ICタグ台帳]
                    WHERE LTRIM(RTRIM([tag_id2])) = @epc";
                await using (var ledgerCmd = new SqlCommand(ledgerSql, connection, transaction))
                {
                    ledgerCmd.Parameters.Add(new SqlParameter("@epc", System.Data.SqlDbType.NVarChar, 50) { Value = epc });
                    var scalar = await ledgerCmd.ExecuteScalarAsync(cancellationToken);
                    if (scalar == null || scalar == DBNull.Value)
                    {
                        missingEpcs.Add(epc);
                        continue;
                    }
                    if (scalar is int i)
                        ledgerProductCode = i;
                    else if (int.TryParse(scalar.ToString(), out var parsedCode))
                        ledgerProductCode = parsedCode;
                }

                if (productCode != null && int.TryParse(productCode, out var reqCode) &&
                    ledgerProductCode.HasValue && reqCode != ledgerProductCode.Value)
                {
                    warnings.Add($"EPC {epc}: リクエスト商品コード {reqCode} と台帳 {ledgerProductCode.Value} が一致しません（台帳を優先）。");
                }

                if (ledgerProductCode.HasValue && detailProductCodes.Count > 0 && !detailProductCodes.Contains(ledgerProductCode.Value))
                {
                    warnings.Add($"EPC {epc}: 商品コード {ledgerProductCode.Value} は受付明細にありません。");
                    _logger.LogWarning("link-tags: product {ProductCode} not in reception {ReceptionNo} details (epc={Epc})",
                        ledgerProductCode.Value, receptionNoInt, epc);
                }

                // 3. ICタグ台帳の tag_mode2 を更新
                const string updateSql = @"
                    UPDATE [dbo].[ICタグ台帳]
                    SET [tag_mode2] = @ledgerTagMode2,
                        [updated] = CONVERT(DATETIME, CONVERT(VARCHAR(19), GETDATE(), 120), 120)
                    WHERE LTRIM(RTRIM([tag_id2])) = @epc";
                await using (var updateCmd = new SqlCommand(updateSql, connection, transaction))
                {
                    updateCmd.Parameters.Add(new SqlParameter("@epc", System.Data.SqlDbType.NVarChar, 50) { Value = epc });
                    updateCmd.Parameters.Add(new SqlParameter("@ledgerTagMode2", System.Data.SqlDbType.NVarChar, 20) { Value = ledgerTagMode2 });
                    await updateCmd.ExecuteNonQueryAsync(cancellationToken);
                }

                // 4. 再送対策: 未転記行、および complete=1 で同モードの行を削除
                const string deleteSql = @"
                    DELETE FROM [dbo].[tag_table3]
                    WHERE [受付番号] = @receptionNo
                      AND LTRIM(RTRIM([tag_id2])) = @epc
                      AND (
                        ISNULL([complete], 0) = 0
                        OR (
                          @table3Complete = 1
                          AND ISNULL([tag_mode], N'') = @table3TagMode
                        )
                      )";
                await using (var deleteCmd = new SqlCommand(deleteSql, connection, transaction))
                {
                    deleteCmd.Parameters.Add(new SqlParameter("@receptionNo", System.Data.SqlDbType.Int) { Value = receptionNoInt });
                    deleteCmd.Parameters.Add(new SqlParameter("@epc", System.Data.SqlDbType.NVarChar, 50) { Value = epc });
                    deleteCmd.Parameters.Add(new SqlParameter("@table3Complete", System.Data.SqlDbType.Int) { Value = table3Complete });
                    deleteCmd.Parameters.Add(new SqlParameter("@table3TagMode", System.Data.SqlDbType.NVarChar, 20) { Value = table3TagMode });
                    await deleteCmd.ExecuteNonQueryAsync(cancellationToken);
                }

                // 5. tag_table3 に INSERT（mark=0, 印刷=0。complete はモード依存）
                const string insertSql = @"
                    INSERT INTO [dbo].[tag_table3]
                        ([read_time], [tag_id2], [tag_mode], [s_code], [受付番号], [mark], [complete], [印刷])
                    VALUES
                        (CONVERT(DATETIME, CONVERT(VARCHAR(19), GETDATE(), 120), 120),
                         @epc, @table3TagMode, @sCode, @receptionNo, 0, @table3Complete, 0)";
                await using (var insertCmd = new SqlCommand(insertSql, connection, transaction))
                {
                    insertCmd.Parameters.Add(new SqlParameter("@epc", System.Data.SqlDbType.NVarChar, 50) { Value = epc });
                    insertCmd.Parameters.Add(new SqlParameter("@table3TagMode", System.Data.SqlDbType.NVarChar, 20) { Value = table3TagMode });
                    insertCmd.Parameters.Add(new SqlParameter("@sCode", System.Data.SqlDbType.Int) { Value = (object?)sCode ?? DBNull.Value });
                    insertCmd.Parameters.Add(new SqlParameter("@receptionNo", System.Data.SqlDbType.Int) { Value = receptionNoInt });
                    insertCmd.Parameters.Add(new SqlParameter("@table3Complete", System.Data.SqlDbType.Int) { Value = table3Complete });
                    await insertCmd.ExecuteNonQueryAsync(cancellationToken);
                }
            }

            if (missingEpcs.Count > 0)
            {
                await transaction.RollbackAsync(cancellationToken);
                return NotFound(new
                {
                    message = "ICタグ台帳に存在しないタグがあります。",
                    missingEpcs,
                    receptionNo = receptionNoInt.ToString(),
                });
            }

            await transaction.CommitAsync(cancellationToken);

            return Ok(new ReceptionSlipLinkTagsResponseDto
            {
                ReceptionNo = receptionNoInt.ToString(),
                Linked = items.Count,
                Warnings = warnings,
            });
        }
        catch
        {
            await transaction.RollbackAsync(cancellationToken);
            throw;
        }
    }
}
