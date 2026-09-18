using System.Text.Json.Serialization;

namespace TagReaderApi.Models;

/// <summary>
/// POST /api/reception-slips/{receptionNo}/link-tags のリクエスト Body。
/// </summary>
public class ReceptionSlipLinkTagsRequestDto
{
    [JsonPropertyName("user_id")]
    public string? UserId { get; set; }

    /// <summary>
    /// 用件が「交換」のとき必須。<c>交換納品</c> または <c>交換返品</c>。
    /// 他用件では無視する。
    /// </summary>
    [JsonPropertyName("link_mode")]
    public string? LinkMode { get; set; }

    [JsonPropertyName("items")]
    public List<ReceptionSlipLinkTagItemDto> Items { get; set; } = new();
}

public class ReceptionSlipLinkTagItemDto
{
    /// <summary>タグ ID（[ICタグ台帳].[tag_id2]）</summary>
    [JsonPropertyName("epc")]
    public string Epc { get; set; } = string.Empty;

    /// <summary>商品コード（照合用・任意。存在しない EPC のみハードエラー）</summary>
    [JsonPropertyName("product_code")]
    public string? ProductCode { get; set; }
}
