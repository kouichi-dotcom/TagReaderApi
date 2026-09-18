using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using TagReaderApi.Models;

namespace TagReaderApi.Controllers;

[ApiController]
[Route("api/[controller]")]
public class ProductsController : ControllerBase
{
    /// <summary>個体一覧で返す tag_mode2（表記ゆれ除去後にこのいずれかと一致するもののみ）。</summary>
    private static readonly HashSet<string> AllowedInventoryTagModes = new(StringComparer.Ordinal)
    {
        "OK", "ＯＫ", "在庫", "清掃中", "整備中",
    };

    private readonly string _connectionString;
    private readonly bool _readOnly;

    public ProductsController(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
        _readOnly = configuration.GetValue("Database:ReadOnly", false);
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
    /// [ICタグ台帳] から tag_id2・商品ｺｰﾄﾞ・番号を一括取得（廃棄除外）。
    /// アプリの1日初回起動時タグ台帳キャッシュ用。
    /// </summary>
    [HttpGet("tag-ledger")]
    [ProducesResponseType(typeof(IEnumerable<TagLedgerItemDto>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetTagLedger(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        const string sql = @"
            SELECT i.[tag_id2], i.[商品ｺｰﾄﾞ], i.[番号]
            FROM [dbo].[ICタグ台帳] i
            WHERE i.[tag_id2] IS NOT NULL
              AND LTRIM(RTRIM(i.[tag_id2])) <> ''
              AND (i.[tag_mode2] IS NULL OR i.[tag_mode2] <> N'廃棄')";

        await using var cmd = new SqlCommand(sql, connection);
        var list = new List<TagLedgerItemDto>();
        await using (var reader = await cmd.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                list.Add(new TagLedgerItemDto
                {
                    TagId2 = reader.IsDBNull(0) ? string.Empty : reader.GetString(0).Trim(),
                    ProductCode = reader.IsDBNull(1) ? null : reader.GetInt32(1),
                    Number = reader.IsDBNull(2) ? null : reader.GetInt32(2)
                });
            }
        }

        return Ok(list);
    }

    /// <summary>
    /// 指定商品コードの次番号（MAX([番号])+1）。台帳に無い場合は 1。
    /// </summary>
    [HttpGet("tag-ledger/next-number")]
    [ProducesResponseType(typeof(TagLedgerNextNumberDto), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> GetNextNumber([FromQuery] int? code, CancellationToken cancellationToken = default)
    {
        if (code == null || code <= 0)
            return BadRequest(new { message = "code を指定してください。" });

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        const string sql = @"
            SELECT ISNULL(MAX([番号]), 0) + 1
            FROM [dbo].[ICタグ台帳]
            WHERE [商品ｺｰﾄﾞ] = @code";

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.Add(new SqlParameter("@code", System.Data.SqlDbType.Int) { Value = code.Value });
        var next = (int)(await cmd.ExecuteScalarAsync(cancellationToken) ?? 1);

        return Ok(new TagLedgerNextNumberDto
        {
            ProductCode = code.Value,
            NextNumber = next
        });
    }

    /// <summary>
    /// [ICタグ台帳] に tag_id2 × 商品コード × 番号 を新規登録する。
    /// 設定列: 商品ｺｰﾄﾞ, 番号, 取得日, tag_id2, tag_mode2=登録, updated, 担当者名, registration_date。他は NULL。
    /// </summary>
    [HttpPost("tag-ledger")]
    [ProducesResponseType(typeof(TagLedgerRegisterResponseDto), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<IActionResult> RegisterTagLedger(
        [FromBody] TagLedgerRegisterRequestDto? body,
        CancellationToken cancellationToken = default)
    {
        if (_readOnly)
            return Conflict(new { message = "読み取り専用 DB のため登録できません。" });

        if (body == null || string.IsNullOrWhiteSpace(body.Epc))
            return BadRequest(new { message = "epc は必須です。" });
        if (body.ProductCode is null or <= 0)
            return BadRequest(new { message = "product_code は必須です。" });
        if (!body.AutoNumber && (body.Number is null or <= 0))
            return BadRequest(new { message = "number を指定するか auto_number を true にしてください。" });

        var epc = body.Epc.Trim();
        var productCode = body.ProductCode.Value;
        var staffName = string.IsNullOrWhiteSpace(body.UserName) ? null : body.UserName.Trim();

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);

        try
        {
            // 商品台帳に存在するか
            const string productSql = @"SELECT COUNT(1) FROM [dbo].[商品台帳] WHERE [商品コード] = @code";
            await using (var productCmd = new SqlCommand(productSql, connection, transaction))
            {
                productCmd.Parameters.Add(new SqlParameter("@code", System.Data.SqlDbType.Int) { Value = productCode });
                var productCount = (int)(await productCmd.ExecuteScalarAsync(cancellationToken) ?? 0);
                if (productCount == 0)
                {
                    await transaction.RollbackAsync(cancellationToken);
                    return NotFound(new { message = "指定の商品コードが商品台帳にありません。", productCode });
                }
            }

            // 同一 tag_id2 の重複
            const string epcSql = @"
                SELECT COUNT(1) FROM [dbo].[ICタグ台帳]
                WHERE LTRIM(RTRIM([tag_id2])) = @epc";
            await using (var epcCmd = new SqlCommand(epcSql, connection, transaction))
            {
                epcCmd.Parameters.Add(new SqlParameter("@epc", System.Data.SqlDbType.NVarChar, 50) { Value = epc });
                var epcCount = (int)(await epcCmd.ExecuteScalarAsync(cancellationToken) ?? 0);
                if (epcCount > 0)
                {
                    await transaction.RollbackAsync(cancellationToken);
                    return Conflict(new { message = "このタグIDは既に台帳に登録されています。", epc });
                }
            }

            int number;
            if (body.AutoNumber)
            {
                const string nextSql = @"
                    SELECT ISNULL(MAX([番号]), 0) + 1
                    FROM [dbo].[ICタグ台帳] WITH (UPDLOCK, HOLDLOCK)
                    WHERE [商品ｺｰﾄﾞ] = @code";
                await using var nextCmd = new SqlCommand(nextSql, connection, transaction);
                nextCmd.Parameters.Add(new SqlParameter("@code", System.Data.SqlDbType.Int) { Value = productCode });
                number = (int)(await nextCmd.ExecuteScalarAsync(cancellationToken) ?? 1);
            }
            else
            {
                number = body.Number!.Value;
                const string dupSql = @"
                    SELECT COUNT(1) FROM [dbo].[ICタグ台帳]
                    WHERE [商品ｺｰﾄﾞ] = @code AND [番号] = @number";
                await using var dupCmd = new SqlCommand(dupSql, connection, transaction);
                dupCmd.Parameters.Add(new SqlParameter("@code", System.Data.SqlDbType.Int) { Value = productCode });
                dupCmd.Parameters.Add(new SqlParameter("@number", System.Data.SqlDbType.Int) { Value = number });
                var dupCount = (int)(await dupCmd.ExecuteScalarAsync(cancellationToken) ?? 0);
                if (dupCount > 0)
                {
                    await transaction.RollbackAsync(cancellationToken);
                    return Conflict(new
                    {
                        message = "同じ商品コードと番号の組み合わせが既に存在します。",
                        productCode,
                        number
                    });
                }
            }

            const string insertSql = @"
                INSERT INTO [dbo].[ICタグ台帳]
                    ([商品ｺｰﾄﾞ], [番号], [取得日], [tag_id2], [tag_mode2], [updated], [担当者名], [registration_date])
                VALUES
                    (@productCode, @number,
                     CONVERT(DATETIME, CONVERT(VARCHAR(19), GETDATE(), 120), 120),
                     @epc, N'登録',
                     CONVERT(DATETIME, CONVERT(VARCHAR(19), GETDATE(), 120), 120),
                     @staffName,
                     CONVERT(DATETIME, CONVERT(VARCHAR(19), GETDATE(), 120), 120))";

            await using (var insertCmd = new SqlCommand(insertSql, connection, transaction))
            {
                insertCmd.Parameters.Add(new SqlParameter("@productCode", System.Data.SqlDbType.Int) { Value = productCode });
                insertCmd.Parameters.Add(new SqlParameter("@number", System.Data.SqlDbType.Int) { Value = number });
                insertCmd.Parameters.Add(new SqlParameter("@epc", System.Data.SqlDbType.NVarChar, 50) { Value = epc });
                insertCmd.Parameters.Add(new SqlParameter("@staffName", System.Data.SqlDbType.NVarChar, 50)
                {
                    Value = (object?)staffName ?? DBNull.Value
                });
                await insertCmd.ExecuteNonQueryAsync(cancellationToken);
            }

            await transaction.CommitAsync(cancellationToken);

            return Ok(new TagLedgerRegisterResponseDto
            {
                TagId2 = epc,
                ProductCode = productCode,
                Number = number,
                TagMode2 = "登録"
            });
        }
        catch
        {
            await transaction.RollbackAsync(cancellationToken);
            throw;
        }
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

    /// <summary>
    /// 在庫確認: 商品コードに一致する [ICタグ台帳] の行を個体一覧で返す（番号・tag_mode2・メーカー等）。
    /// [番号]・[tag_mode2] が NULL の行は ICタグ未付与として除外する。
    /// 型式は [商品台帳].[型   式] を使用（[ICタグ台帳] に型式列が無い環境があるため個体側は参照しない）。
    /// [メーカー][備考][取得日] は [ICタグ台帳] 列名の前提（無い場合は SQL を DB に合わせて修正）。
    /// tag_mode2 は OK／在庫／清掃中（および全角 ＯＫ）のみ返し、廃棄などは含めない。
    /// </summary>
    [HttpGet("inventory/units")]
    [ProducesResponseType(typeof(IEnumerable<InventoryUnitRowDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> GetInventoryUnits([FromQuery] int? code, CancellationToken cancellationToken = default)
    {
        if (code == null)
            return BadRequest("code を指定してください。");

        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        const string sql = @"
            SELECT
                i.[番号] AS numberOrdinal,
                i.[tag_mode2] AS tagMode2,
                COALESCE(NULLIF(RTRIM(CAST(i.[メーカー] AS NVARCHAR(200))), N''), N'') AS manufacturer,
                COALESCE(NULLIF(RTRIM(CAST(s.[型   式] AS NVARCHAR(200))), N''), N'') AS modelType,
                COALESCE(NULLIF(RTRIM(CAST(i.[備考] AS NVARCHAR(500))), N''), N'') AS remarks,
                CASE
                    WHEN i.[取得日] IS NULL THEN NULL
                    ELSE CONVERT(VARCHAR(10), TRY_CAST(i.[取得日] AS DATE), 111)
                END AS acquisitionDateYmd
            FROM [dbo].[ICタグ台帳] i
            LEFT JOIN [dbo].[商品台帳] s ON s.[商品コード] = i.[商品ｺｰﾄﾞ]
            WHERE i.[商品ｺｰﾄﾞ] = @code
              AND i.[番号] IS NOT NULL
              AND i.[tag_mode2] IS NOT NULL
              AND REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(i.[tag_mode2])), NCHAR(0x3000), N''), NCHAR(0xFEFF), N''), NCHAR(0x200B), N'')
                  IN (N'OK', N'ＯＫ', N'在庫', N'清掃中', N'整備中')
            ORDER BY i.[番号]";

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@code", code.Value);

        var list = new List<InventoryUnitRowDto>();
        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        var ordNumber = reader.GetOrdinal("numberOrdinal");
        var ordTagMode2 = reader.GetOrdinal("tagMode2");
        var ordManufacturer = reader.GetOrdinal("manufacturer");
        var ordModelType = reader.GetOrdinal("modelType");
        var ordRemarks = reader.GetOrdinal("remarks");
        var ordDate = reader.GetOrdinal("acquisitionDateYmd");

        while (await reader.ReadAsync(cancellationToken))
        {
            list.Add(new InventoryUnitRowDto
            {
                Number = reader.IsDBNull(ordNumber) ? null : Convert.ToInt32(reader.GetValue(ordNumber)),
                TagMode2 = reader.IsDBNull(ordTagMode2) ? string.Empty : reader.GetString(ordTagMode2),
                Manufacturer = reader.IsDBNull(ordManufacturer) ? string.Empty : reader.GetString(ordManufacturer),
                ModelType = reader.IsDBNull(ordModelType) ? string.Empty : reader.GetString(ordModelType),
                Remarks = reader.IsDBNull(ordRemarks) ? string.Empty : reader.GetString(ordRemarks),
                AcquisitionDateYmd = ReadAcquisitionDateYmd(reader, ordDate),
            });
        }

        list = list.Where(r => AllowedInventoryTagModes.Contains(NormalizeTagMode2ForInventory(r.TagMode2))).ToList();

        return Ok(list);
    }

    /// <summary>LTRIM では落ちない全角スペース等を除いたうえで許可リストと照合する。</summary>
    private static string NormalizeTagMode2ForInventory(string? s)
    {
        if (string.IsNullOrEmpty(s)) return string.Empty;
        var t = s.Trim();
        t = t.Replace("\u3000", "", StringComparison.Ordinal);
        t = t.Replace("\uFEFF", "", StringComparison.Ordinal);
        t = t.Replace("\u200B", "", StringComparison.Ordinal);
        return t.Trim();
    }

    private static string? ReadAcquisitionDateYmd(SqlDataReader reader, int ordinal)
    {
        if (reader.IsDBNull(ordinal)) return null;
        var v = reader.GetValue(ordinal);
        if (v is DateTime dt) return dt.ToString("yyyy/MM/dd");
        var s = v.ToString()?.Trim();
        if (string.IsNullOrEmpty(s)) return null;
        if (s.Length >= 10 && s[4] == '/' && s[7] == '/') return s[..10];
        return s;
    }

    /// <summary>
    /// 在庫確認の区分グリッド用: [商品区分マスター] を ID 順で返す（販売・区分なし除外）。
    /// </summary>
    [HttpGet("categories")]
    [ProducesResponseType(typeof(IEnumerable<ProductCategoryDto>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetCategories(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        const string sql = @"
            SELECT [商品区分ID] AS id, [商品区分] AS name
            FROM [dbo].[商品区分マスター]
            WHERE [商品区分] IS NOT NULL
              AND LTRIM(RTRIM([商品区分])) NOT IN (N'販売', N'区分なし')
            ORDER BY [商品区分ID]";

        await using var cmd = new SqlCommand(sql, connection);
        var list = new List<ProductCategoryDto>();
        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        var ordId = reader.GetOrdinal("id");
        var ordName = reader.GetOrdinal("name");

        while (await reader.ReadAsync(cancellationToken))
        {
            list.Add(new ProductCategoryDto
            {
                Id = Convert.ToInt32(reader.GetValue(ordId)),
                Name = reader.IsDBNull(ordName) ? string.Empty : reader.GetString(ordName).Trim(),
            });
        }

        return Ok(list);
    }

    /// <summary>
    /// 在庫確認用: [商品台帳] と [ICタグ台帳] の tag_mode2 集計を商品区分付きで返す。
    /// ICタグ未付与（[番号] または [tag_mode2] が NULL）の行は集計・一覧から除外する。
    /// 集計対象の tag_mode2 は OK／ＯＫ／在庫／清掃中／整備中 のみ（廃棄・自社使用・貸出中などは除外）。
    /// categoryId で商品区分を絞り込み、q で商品名・商品コードを部分一致検索できる。
    /// </summary>
    [HttpGet("inventory")]
    [ProducesResponseType(typeof(IEnumerable<InventoryItemDto>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetInventory(
        [FromQuery] int? categoryId,
        [FromQuery] string? q,
        CancellationToken cancellationToken = default)
    {
        await using var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);

        const string sql = @"
            WITH InventoryCounts AS (
                SELECT
                    [商品ｺｰﾄﾞ],
                    SUM(CASE WHEN [tag_mode2] IN (N'OK', N'ＯＫ') THEN 1 ELSE 0 END) AS countOk,
                    SUM(CASE WHEN [tag_mode2] = N'在庫' THEN 1 ELSE 0 END) AS countStorage,
                    SUM(CASE WHEN [tag_mode2] = N'清掃中' THEN 1 ELSE 0 END) AS countCleaning,
                    SUM(CASE WHEN [tag_mode2] = N'整備中' THEN 1 ELSE 0 END) AS countMaintenance
                FROM [dbo].[ICタグ台帳]
                WHERE [商品ｺｰﾄﾞ] IS NOT NULL
                  AND [番号] IS NOT NULL
                  AND [tag_mode2] IS NOT NULL
                  AND REPLACE(REPLACE(REPLACE(LTRIM(RTRIM([tag_mode2])), NCHAR(0x3000), N''), NCHAR(0xFEFF), N''), NCHAR(0x200B), N'')
                      IN (N'OK', N'ＯＫ', N'在庫', N'清掃中', N'整備中')
                GROUP BY [商品ｺｰﾄﾞ]
            )
            SELECT
                p.[商品コード] AS id,
                p.[商品名] AS name,
                p.[商品区分ID] AS categoryId,
                COALESCE(kubun.[商品区分], N'未分類') AS category,
                COALESCE(p.[型   式], N'') AS sku,
                N'' AS imageUrl,
                COALESCE(p.[型   式], N'') AS description,
                COALESCE(p.[基本料], 0) AS baseFee,
                COALESCE(p.[単価 (日)], 0) AS dailyPrice,
                COALESCE(p.[単価 (月)], 0) AS monthlyPrice,
                ic.countOk AS countOk,
                ic.countStorage AS countStorage,
                ic.countCleaning AS countCleaning,
                ic.countMaintenance AS countMaintenance,
                0 AS countRented
            FROM [dbo].[商品台帳] p
            LEFT JOIN [dbo].[商品区分マスター] kubun
                ON p.[商品区分ID] = kubun.[商品区分ID]
            INNER JOIN InventoryCounts ic
                ON p.[商品コード] = ic.[商品ｺｰﾄﾞ]
            WHERE p.[現存する商品] = 1
              AND (@categoryId IS NULL OR p.[商品区分ID] = @categoryId)
              AND (
                  @q IS NULL OR @q = N''
                  OR p.[商品名] LIKE N'%' + @q + N'%'
                  OR CAST(p.[商品コード] AS NVARCHAR(20)) LIKE N'%' + @q + N'%'
              )
            ORDER BY p.[商品区分ID], p.[商品コード]";

        await using var cmd = new SqlCommand(sql, connection);
        cmd.Parameters.AddWithValue("@categoryId", categoryId.HasValue ? categoryId.Value : DBNull.Value);
        var qTrim = q?.Trim();
        cmd.Parameters.AddWithValue("@q", string.IsNullOrEmpty(qTrim) ? DBNull.Value : qTrim);
        var list = new List<InventoryItemDto>();
        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        var ordId = reader.GetOrdinal("id");
        var ordName = reader.GetOrdinal("name");
        var ordCategoryId = reader.GetOrdinal("categoryId");
        var ordCategory = reader.GetOrdinal("category");
        var ordSku = reader.GetOrdinal("sku");
        var ordImageUrl = reader.GetOrdinal("imageUrl");
        var ordDescription = reader.GetOrdinal("description");
        var ordBaseFee = reader.GetOrdinal("baseFee");
        var ordDailyPrice = reader.GetOrdinal("dailyPrice");
        var ordMonthlyPrice = reader.GetOrdinal("monthlyPrice");
        var ordCountOk = reader.GetOrdinal("countOk");
        var ordCountStorage = reader.GetOrdinal("countStorage");
        var ordCountCleaning = reader.GetOrdinal("countCleaning");
        var ordCountMaintenance = reader.GetOrdinal("countMaintenance");
        var ordCountRented = reader.GetOrdinal("countRented");

        while (await reader.ReadAsync(cancellationToken))
        {
            list.Add(new InventoryItemDto
            {
                Id = reader.IsDBNull(ordId) ? string.Empty : reader.GetValue(ordId)?.ToString() ?? string.Empty,
                Name = reader.IsDBNull(ordName) ? string.Empty : reader.GetString(ordName),
                CategoryId = reader.IsDBNull(ordCategoryId) ? null : Convert.ToInt32(reader.GetValue(ordCategoryId)),
                Category = reader.IsDBNull(ordCategory) ? string.Empty : reader.GetString(ordCategory),
                Sku = reader.IsDBNull(ordSku) ? string.Empty : reader.GetString(ordSku),
                ImageUrl = reader.IsDBNull(ordImageUrl) ? string.Empty : reader.GetString(ordImageUrl),
                Description = reader.IsDBNull(ordDescription) ? string.Empty : reader.GetString(ordDescription),
                BaseFee = ReadPositiveMoney(reader, ordBaseFee),
                DailyPrice = ReadPositiveMoney(reader, ordDailyPrice),
                MonthlyPrice = ReadPositiveMoney(reader, ordMonthlyPrice),
                CountOk = ReadInt(reader, ordCountOk),
                CountStorage = ReadInt(reader, ordCountStorage),
                CountCleaning = ReadInt(reader, ordCountCleaning),
                CountMaintenance = ReadInt(reader, ordCountMaintenance),
                CountRented = ReadInt(reader, ordCountRented),
            });
        }

        return Ok(list);
    }

    private static int ReadInt(SqlDataReader reader, int ordinal)
    {
        if (reader.IsDBNull(ordinal)) return 0;
        return Convert.ToInt32(reader.GetValue(ordinal));
    }

    /// <summary>0 以下や null は未設定（アプリ側で非表示）にする。</summary>
    private static double? ReadPositiveMoney(SqlDataReader reader, int ordinal)
    {
        if (reader.IsDBNull(ordinal)) return null;
        var v = reader.GetValue(ordinal);
        double d = v switch
        {
            decimal x => (double)x,
            double x => x,
            float x => x,
            int x => x,
            long x => x,
            _ => double.TryParse(v.ToString()?.Replace(",", ""), System.Globalization.NumberStyles.Any,
                System.Globalization.CultureInfo.InvariantCulture, out var p)
                ? p
                : 0
        };
        return d > 0 ? d : null;
    }
}
