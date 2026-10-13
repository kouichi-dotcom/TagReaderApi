using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using TagReaderApi.Models;

namespace TagReaderApi.Controllers;

[ApiController]
[Route("api/product-updates")]
public class ProductUpdatesController : ControllerBase
{
    private const int StatusMaxLength = 30;

    private readonly string _connectionString;

    public ProductUpdatesController(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
    }

    /// <summary>
    /// 商品データ（ステータス等）の変更を送信し、[ICタグ台帳] の tag_mode2 を更新する。
    /// storage_location 指定時は [保管場所コード] も更新する。
    /// </summary>
    [HttpPost]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Post([FromBody] ProductUpdateRequestDto? body, CancellationToken cancellationToken = default)
    {
        if (body == null || string.IsNullOrWhiteSpace(body.Epc))
            return BadRequest("epc は必須です。");

        var epc = body.Epc.Trim();

        if (body.Changes == null || !body.Changes.TryGetValue("status", out var statusElement))
            return BadRequest("changes.status を指定してください。");

        if (statusElement.ValueKind == JsonValueKind.Null || statusElement.ValueKind == JsonValueKind.Undefined)
            return BadRequest("changes.status を指定してください。");

        if (statusElement.ValueKind != JsonValueKind.String)
            return BadRequest("changes.status は文字列である必要があります。");

        var status = statusElement.GetString();
        if (string.IsNullOrWhiteSpace(status))
            return BadRequest("changes.status を指定してください。");

        status = status.Trim();
        if (status.Length > StatusMaxLength)
            return BadRequest($"changes.status は{StatusMaxLength}文字以内で指定してください。");

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);

        try
        {
            // storage_location（1〜4）指定時のみ [保管場所コード] を更新。未指定時は現状維持。
            var storageLocationCode = body.StorageLocation is >= 1 and <= 4 ? body.StorageLocation : null;
            var sql = storageLocationCode.HasValue
                ? @"
            UPDATE [dbo].[ICタグ台帳]
            SET [tag_mode2] = @status,
                [保管場所コード] = @storageLocationCode,
                [updated] = CONVERT(DATETIME, CONVERT(VARCHAR(19), GETDATE(), 120), 120)
            WHERE LTRIM(RTRIM([tag_id2])) = @epc"
                : @"
            UPDATE [dbo].[ICタグ台帳]
            SET [tag_mode2] = @status,
                [updated] = CONVERT(DATETIME, CONVERT(VARCHAR(19), GETDATE(), 120), 120)
            WHERE LTRIM(RTRIM([tag_id2])) = @epc";

            await using (var cmd = new SqlCommand(sql, connection, transaction))
            {
                cmd.Parameters.Add(new SqlParameter("@epc", System.Data.SqlDbType.NVarChar, 50) { Value = epc });
                cmd.Parameters.Add(new SqlParameter("@status", System.Data.SqlDbType.NVarChar, StatusMaxLength) { Value = status });
                if (storageLocationCode.HasValue)
                    cmd.Parameters.Add(new SqlParameter("@storageLocationCode", System.Data.SqlDbType.Int) { Value = storageLocationCode.Value });

                var rows = await cmd.ExecuteNonQueryAsync(cancellationToken);
                if (rows == 0)
                {
                    await transaction.RollbackAsync(cancellationToken);
                    return NotFound(new
                    {
                        message = "該当するタグ（epc）が見つかりませんでした。",
                        receivedEpc = epc,
                        receivedEpcLength = epc.Length,
                    });
                }

                // ステータス更新ログを [tag_table4] に記録（ID は自動、read_time=サーバー現在時刻, tag_id2, tag_mode, s_code=従業員コード）
                int? sCode = null;
                if (!string.IsNullOrWhiteSpace(body.UserId) && int.TryParse(body.UserId.Trim(), out var parsed))
                    sCode = parsed;

                // read_time は秒まで（コンマ秒・ミリ秒は不要）。受付番号=0, mark=0, complete=1, Remarks=NULL
                const string insertLogSql = @"
            INSERT INTO [dbo].[tag_table4] ([read_time], [tag_id2], [tag_mode], [s_code], [受付番号], [mark], [complete], [Remarks])
            VALUES (CONVERT(DATETIME, CONVERT(VARCHAR(19), GETDATE(), 120), 120), @epcLog, @statusLog, @sCode, 0, 0, 1, NULL)";
                await using var cmdLog = new SqlCommand(insertLogSql, connection, transaction);
                cmdLog.Parameters.Add(new SqlParameter("@epcLog", System.Data.SqlDbType.NVarChar, 50) { Value = epc });
                cmdLog.Parameters.Add(new SqlParameter("@statusLog", System.Data.SqlDbType.NVarChar, 50) { Value = status });
                cmdLog.Parameters.Add(new SqlParameter("@sCode", System.Data.SqlDbType.Int) { Value = (object?)sCode ?? DBNull.Value });
                await cmdLog.ExecuteNonQueryAsync(cancellationToken);

                await transaction.CommitAsync(cancellationToken);
                return Ok(new { updated = rows, logRecorded = true });
            }
        }
        catch
        {
            try { await transaction.RollbackAsync(cancellationToken); } catch { /* already completed */ }
            throw;
        }
    }
}
