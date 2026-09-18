using System.Text.Json.Serialization;

namespace TagReaderApi.Models;

/// <summary>
/// POST /api/reception-slips/{receptionNo}/link-tags のレスポンス。
/// </summary>
public class ReceptionSlipLinkTagsResponseDto
{
    [JsonPropertyName("receptionNo")]
    public string ReceptionNo { get; set; } = string.Empty;

    [JsonPropertyName("linked")]
    public int Linked { get; set; }

    [JsonPropertyName("warnings")]
    public List<string> Warnings { get; set; } = new();
}
