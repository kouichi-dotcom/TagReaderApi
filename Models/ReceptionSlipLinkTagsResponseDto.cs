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

    /// <summary>
    /// 引取／来店(返品)で [納品明細].[返却] を 1 に更新した行数。他用件では 0。
    /// </summary>
    [JsonPropertyName("deliveryReturnUpdated")]
    public int DeliveryReturnUpdated { get; set; }

    [JsonPropertyName("warnings")]
    public List<string> Warnings { get; set; } = new();
}
