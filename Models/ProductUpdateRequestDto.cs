using System.Text.Json;
using System.Text.Json.Serialization;

namespace TagReaderApi.Models;

/// <summary>
/// POST /api/product-updates のリクエスト Body（API設計に基づく）
/// </summary>
public class ProductUpdateRequestDto
{
    [JsonPropertyName("epc")]
    public string Epc { get; set; } = string.Empty;

    [JsonPropertyName("product_id")]
    public string? ProductId { get; set; }

    [JsonPropertyName("read_at")]
    public string ReadAt { get; set; } = string.Empty;

    [JsonPropertyName("changes")]
    public Dictionary<string, JsonElement>? Changes { get; set; }

    [JsonPropertyName("device_id")]
    public string? DeviceId { get; set; }

    [JsonPropertyName("user_id")]
    public string? UserId { get; set; }

    /// <summary>保管場所（0=非表示, 1=本社, 2=山川, 3=東風平, 4=友寄）。テスト環境でのみ [ICタグ台帳].tag_mode に反映。</summary>
    [JsonPropertyName("storage_location")]
    public int? StorageLocation { get; set; }
}
