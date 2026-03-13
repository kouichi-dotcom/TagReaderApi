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

    public ReceptionSlipsController(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
    }

    /// <summary>
    /// 受付伝票一覧を取得。
    /// 絞り込み: 受付日時が指定日（省略時は当日）、転記済み=0、処理者=担当者コード。
    /// unassignedOnly=true のときは「配達担当者が未定の伝票」のみ（処理者未入力）。
    /// </summary>
    /// <param name="date">受付日（yyyy-MM-dd）。省略時は当日</param>
    /// <param name="assigneeCode">担当者コード（配達担当）。unassignedOnly=false のとき処理者と一致する伝票を表示</param>
    /// <param name="unassignedOnly">true: 配達担当者未定（処理者未入力）の伝票のみ。このとき assigneeCode は不要</param>
    /// <param name="random">true: ランダム10件（テスト用）。このとき date/assigneeCode/unassignedOnly は無視</param>
    /// <param name="subjects">用件で絞り込み（カンマ区切り）。例: 来店(納品),来店(返品)。指定時は日付絞りをせず最新10件</param>
    [HttpGet]
    [ProducesResponseType(typeof(IEnumerable<ReceptionSlipDto>), StatusCodes.Status200OK)]
    public async Task<IActionResult> Get(
        [FromQuery] DateTime? date,
        [FromQuery] string? assigneeCode,
        [FromQuery] bool unassignedOnly = false,
        [FromQuery] bool random = false,
        [FromQuery] string? subjects = null,
        CancellationToken cancellationToken = default)
    {
        var targetDate = date?.Date ?? DateTime.Today;
        var subjectList = subjects?
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(s => !string.IsNullOrWhiteSpace(s))
            .Select(s => s!.Trim())
            .Distinct()
            .ToList() ?? new List<string>();

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        string whereClause;
        string orderClause;
        if (random)
        {
            // ランダム10件（テスト用）: 異常日時のみ除外
            var minValidDate = new DateTime(1900, 1, 1);
            var maxValidDate = DateTime.Today.AddDays(1);
            whereClause = $@"WHERE r.[受付日時] IS NOT NULL
                AND r.[受付日時] >= '{minValidDate:yyyy-MM-dd}'
                AND r.[受付日時] < '{maxValidDate:yyyy-MM-dd}'";
            orderClause = "ORDER BY NEWID()";
        }
        else
        {
            var whereConditions = new List<string>();
            var maxValidDate = DateTime.Today.AddDays(1);
            var minValidDate = new DateTime(1900, 1, 1);
            whereConditions.Add("r.[受付日時] IS NOT NULL");
            whereConditions.Add($"r.[受付日時] >= '{minValidDate:yyyy-MM-dd}'");
            whereConditions.Add($"r.[受付日時] < '{maxValidDate:yyyy-MM-dd}'");
            // 用件絞り（来店伝票等）のときは日付条件を付けず、全期間から最新10件
            if (subjectList.Count > 0)
            {
                whereConditions.Add("ISNULL(r.[転記済], 0) = 0");
                var subjectCondition = subjectList.Count == 1
                    ? $"p.[用件] = @subject0"
                    : "(" + string.Join(" OR ", subjectList.Select((_, i) => $"p.[用件] = @subject{i}")) + ")";
                whereConditions.Add(subjectCondition);
            }
            else
            {
                whereConditions.Add("ISNULL(r.[転記済], 0) = 0");
                if (date.HasValue)
                    whereConditions.Add("CAST(r.[受付日時] AS DATE) = @targetDate");
                if (!unassignedOnly && !string.IsNullOrWhiteSpace(assigneeCode))
                    whereConditions.Add("r.[処理者] = CAST(@assigneeCode AS smallint)");
                else if (unassignedOnly)
                    whereConditions.Add("r.[処理者] IS NULL");
            }
            whereClause = "WHERE " + string.Join(" AND ", whereConditions);
            orderClause = "ORDER BY r.[受付日時] DESC, r.[受付番号] DESC";
        }

        var slipSql = $@"
            SELECT TOP 10
                r.[受付番号], 
                ISNULL(p.[用件], '') AS [用件],
                ISNULL(c.[顧客名], ISNULL(r.[顧客名（その他）], 'その他')) AS CustomerName,
                r.[顧客名（その他）] AS [顧客名その他],
                ISNULL(s.[現場名], ISNULL(r.[現場名（その他）], 'その他')) AS SiteName,
                r.[現場名（その他）] AS [現場名その他],
                r.[期日], d.[期限] AS DeadlineName, r.[期限2] AS [期限２], r.[メモ],
                r.[受付日時], r.[処理者],
                h.[担当者氏名] AS HandlerName
            FROM [dbo].[受付台帳] r
            LEFT JOIN [dbo].[顧客台帳] c ON c.[顧客コード] = r.[顧客コード]
            LEFT JOIN [dbo].[現場台帳] s ON s.[現場ｺｰﾄﾞ] = r.[現場コード]
            LEFT JOIN [dbo].[期限台帳] d ON d.[期限コード] = r.[期限コード]
            LEFT JOIN [dbo].[用件台帳] p ON p.[用件コード] = r.[用件コード]
            LEFT JOIN [dbo].[担当者台帳] h ON h.[担当者コード] = r.[処理者]
            {whereClause}
            {orderClause}";

        await using var cmdSlip = new SqlCommand(slipSql, connection);
        if (!random)
        {
            if (subjectList.Count > 0)
            {
                for (var i = 0; i < subjectList.Count; i++)
                    cmdSlip.Parameters.AddWithValue($"@subject{i}", subjectList[i]);
            }
            else
            {
                if (date.HasValue)
                    cmdSlip.Parameters.AddWithValue("@targetDate", targetDate);
                if (!unassignedOnly && !string.IsNullOrWhiteSpace(assigneeCode) && short.TryParse(assigneeCode, out var assigneeCodeNum))
                    cmdSlip.Parameters.AddWithValue("@assigneeCode", assigneeCodeNum);
            }
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
                    HandlerName = reader.IsDBNull(12) ? null : (string.IsNullOrWhiteSpace(reader.GetString(12)) ? null : reader.GetString(12).Trim())
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
}
