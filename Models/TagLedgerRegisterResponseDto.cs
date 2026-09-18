using System.Text.Json.Serialization;

namespace TagReaderApi.Models;

/// <summary>
/// POST /api/products/tag-ledger のレスポンス。
/// </summary>
public class TagLedgerRegisterResponseDto
{
    [JsonPropertyName("tagId2")]
    public string TagId2 { get; set; } = string.Empty;

    [JsonPropertyName("productCode")]
    public int ProductCode { get; set; }

    [JsonPropertyName("number")]
    public int Number { get; set; }

    [JsonPropertyName("tagMode2")]
    public string TagMode2 { get; set; } = "登録";
}
