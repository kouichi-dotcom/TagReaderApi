using System.Text.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using TagReaderApi.Models;

namespace TagReaderApi.Controllers;

[ApiController]
[Route("api/product-updates")]
public class ProductUpdatesController : ControllerBase
{
    private readonly string _connectionString;

    public ProductUpdatesController(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
    }

    /// <summary>
    /// 商品データ（ステータス等）の変更を送信し、[ICﾀｸﾞ台帳] の tag_mode2 を更新する。
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
        string? status = null;
        if (body.Changes != null && body.Changes.TryGetValue("status", out var statusObj))
        {
            status = statusObj.ValueKind == System.Text.Json.JsonValueKind.String
                ? statusObj.GetString()
                : statusObj.ToString();
        }
        if (string.IsNullOrWhiteSpace(status))
            return BadRequest("changes.status を指定してください。");

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        const string sql = @"
            UPDATE [dbo].[ICﾀｸﾞ台帳]
            SET [tag_mode2] = @status
            WHERE LTRIM(RTRIM([tag_id2])) = @epc";

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.Add(new SqlParameter("@epc", System.Data.SqlDbType.NVarChar, 50) { Value = epc });
        cmd.Parameters.Add(new SqlParameter("@status", System.Data.SqlDbType.NVarChar, 30) { Value = status.Trim() });

        var rows = await cmd.ExecuteNonQueryAsync(cancellationToken);
        if (rows == 0)
        {
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

        // read_time は秒まで（コンマ秒・ミリ秒は不要）
        const string insertLogSql = @"
            INSERT INTO [dbo].[tag_table4] ([read_time], [tag_id2], [tag_mode], [s_code])
            VALUES (CONVERT(DATETIME, CONVERT(VARCHAR(19), GETDATE(), 120), 120), @epcLog, @statusLog, @sCode)";
        await using var cmdLog = new SqlCommand(insertLogSql, connection);
        cmdLog.Parameters.Add(new SqlParameter("@epcLog", System.Data.SqlDbType.NVarChar, 50) { Value = epc });
        cmdLog.Parameters.Add(new SqlParameter("@statusLog", System.Data.SqlDbType.NVarChar, 50) { Value = status.Trim() });
        cmdLog.Parameters.Add(new SqlParameter("@sCode", System.Data.SqlDbType.Int) { Value = (object?)sCode ?? DBNull.Value });
        await cmdLog.ExecuteNonQueryAsync(cancellationToken);

        return Ok(new { updated = rows, logRecorded = true });
    }
}
