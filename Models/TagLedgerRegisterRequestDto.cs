using System.Text.Json.Serialization;

namespace TagReaderApi.Models;

/// <summary>
/// POST /api/products/tag-ledger のリクエスト Body。
/// [ICタグ台帳] に tag_id2 × 商品コード × 番号 を新規登録する。
/// </summary>
public class TagLedgerRegisterRequestDto
{
    [JsonPropertyName("epc")]
    public string Epc { get; set; } = string.Empty;

    [JsonPropertyName("product_code")]
    public int? ProductCode { get; set; }

    /// <summary>手動入力時の番号。auto_number が true のときは無視される。</summary>
    [JsonPropertyName("number")]
    public int? Number { get; set; }

    /// <summary>true のとき、当該商品コードの MAX(番号)+1 を採番する。</summary>
    [JsonPropertyName("auto_number")]
    public bool AutoNumber { get; set; }

    [JsonPropertyName("user_id")]
    public string? UserId { get; set; }

    [JsonPropertyName("user_name")]
    public string? UserName { get; set; }
}
