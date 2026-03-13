using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using TagReaderApi.Models;

namespace TagReaderApi.Controllers;

[ApiController]
[Route("api/[controller]")]
public class ProductsController : ControllerBase
{
    private readonly string _connectionString;

    public ProductsController(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
    }

    /// <summary>
    /// EPC（tag_id2）をキーに [ICタグ台帳] から tag_id2, 商品ｺｰﾄﾞ, 番号, tag_mode2 を取得する。
    /// </summary>
    /// <param name="epc">タグID（tag_id2 と一致させる文字列）</param>
    [HttpGet]
    [ProducesResponseType(typeof(ProductResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetByEpc([FromQuery] string? epc, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(epc))
            return BadRequest("epc を指定してください。");

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        // [ICタグ台帳] + [商品台帳] で 商品名 を取得
        const string sql = @"
            SELECT i.[tag_id2], i.[商品ｺｰﾄﾞ], i.[番号], i.[tag_mode2], s.[商品名]
            FROM [dbo].[ICタグ台帳] i
            LEFT JOIN [dbo].[商品台帳] s ON s.[商品コード] = i.[商品ｺｰﾄﾞ]
            WHERE i.[tag_id2] = @epc";

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@epc", epc.Trim());

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            return NotFound();

        var product = new ProductResponse
        {
            TagId2 = reader.IsDBNull(0) ? string.Empty : reader.GetString(0),
            ProductCode = reader.IsDBNull(1) ? null : reader.GetInt32(1),
            Number = reader.IsDBNull(2) ? null : reader.GetInt32(2),
            Status = reader.IsDBNull(3) ? string.Empty : reader.GetString(3),
            ProductName = reader.IsDBNull(4) ? string.Empty : reader.GetString(4)
        };

        return Ok(product);
    }

    /// <summary>
    /// [ICタグ台帳] からランダムに N 件取得し、[商品台帳] の商品名を JOIN して返す。
    /// タグリーダーがない環境で「読み取りシミュレート」用。
    /// </summary>
    [HttpGet("random")]
    [ProducesResponseType(typeof(IEnumerable<ProductResponse>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetRandom([FromQuery] int count = 5, CancellationToken cancellationToken = default)
    {
        if (count <= 0 || count > 50) count = 5;

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        const string sql = @"
            SELECT TOP (@count) i.[tag_id2], i.[商品ｺｰﾄﾞ], i.[番号], i.[tag_mode2], s.[商品名]
            FROM [dbo].[ICタグ台帳] i
            LEFT JOIN [dbo].[商品台帳] s ON s.[商品コード] = i.[商品ｺｰﾄﾞ]
            ORDER BY NEWID()";

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@count", count);

        var list = new List<ProductResponse>();
        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            list.Add(new ProductResponse
            {
                TagId2 = reader.IsDBNull(0) ? string.Empty : reader.GetString(0),
                ProductCode = reader.IsDBNull(1) ? null : reader.GetInt32(1),
                Number = reader.IsDBNull(2) ? null : reader.GetInt32(2),
                Status = reader.IsDBNull(3) ? string.Empty : reader.GetString(3),
                ProductName = reader.IsDBNull(4) ? string.Empty : reader.GetString(4)
            });
        }

        return Ok(list);
    }

    /// <summary>
    /// [商品台帳] から [現存する商品] = 1 の商品一覧を取得。アプリ初回起動時の商品名キャッシュ用。
    /// </summary>
    [HttpGet("catalog")]
    [ProducesResponseType(typeof(IEnumerable<ProductCatalogItemDto>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetCatalog(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        const string sql = @"
            SELECT [商品コード], [商品名]
            FROM [dbo].[商品台帳]
            WHERE [現存する商品] = 1
            ORDER BY [商品コード]";

        await using var cmd = new SqlCommand(sql, connection);
        var list = new List<ProductCatalogItemDto>();
        await using (var reader = await cmd.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                list.Add(new ProductCatalogItemDto
                {
                    ProductCode = reader.GetInt32(0),
                    ProductName = reader.IsDBNull(1) ? string.Empty : reader.GetString(1)
                });
            }
        }

        return Ok(list);
    }

    /// <summary>
    /// 商品コードをキーに [商品台帳] から 1 件取得。オンデマンド用。
    /// </summary>
    [HttpGet("by-code")]
    [ProducesResponseType(typeof(ProductCatalogItemDto), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetByCode([FromQuery] int? code, CancellationToken cancellationToken = default)
    {
        if (code == null)
            return BadRequest("code を指定してください。");

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        const string sql = @"
            SELECT [商品コード], [商品名]
            FROM [dbo].[商品台帳]
            WHERE [商品コード] = @code";

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@code", code.Value);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            return NotFound();

        var item = new ProductCatalogItemDto
        {
            ProductCode = reader.GetInt32(0),
            ProductName = reader.IsDBNull(1) ? string.Empty : reader.GetString(1)
        };

        return Ok(item);
    }
}
