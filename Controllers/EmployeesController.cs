using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using TagReaderApi.Models;

namespace TagReaderApi.Controllers;

[ApiController]
[Route("api/[controller]")]
public class EmployeesController : ControllerBase
{
    private readonly string _connectionString;

    public EmployeesController(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
    }

    /// <summary>
    /// 担当者コードをキーに [担当者台帳] から担当者氏名を取得する。
    /// アプリで担当者コード入力・ホームに担当者氏名表示・伝票・商品更新時に誰が記録したかを送るために利用。
    /// </summary>
    /// <param name="code">担当者コード（数値として解釈）</param>
    [HttpGet]
    [ProducesResponseType(typeof(EmployeeResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetByCode([FromQuery] string? code, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(code))
            return BadRequest("code を指定してください。");

        if (!short.TryParse(code.Trim(), out var codeValue))
            return BadRequest("担当者コードは数値で指定してください。");

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        const string sql = @"
            SELECT [担当者コード], [担当者氏名]
            FROM [dbo].[担当者台帳]
            WHERE [担当者コード] = @code";

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@code", codeValue);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            return NotFound();

        var employee = new EmployeeResponse
        {
            EmployeeCode = reader.GetInt16(0),
            EmployeeName = reader.IsDBNull(1) ? string.Empty : reader.GetString(1)
        };

        return Ok(employee);
    }
}
