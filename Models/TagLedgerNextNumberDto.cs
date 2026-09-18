using System.Text.Json.Serialization;

namespace TagReaderApi.Models;

/// <summary>
/// GET /api/products/tag-ledger/next-number のレスポンス。
/// </summary>
public class TagLedgerNextNumberDto
{
    [JsonPropertyName("productCode")]
    public int ProductCode { get; set; }

    [JsonPropertyName("nextNumber")]
    public int NextNumber { get; set; }
}
