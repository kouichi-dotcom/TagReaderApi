namespace TagReaderApi.Models;

/// <summary>
/// [ICﾀｸﾞ台帳] + [商品台帳] の tag_id2, 商品ｺｰﾄﾞ, 番号, tag_mode2, 商品名 を返す用。
/// </summary>
public class ProductResponse
{
    public string TagId2 { get; set; } = string.Empty;
    public int? ProductCode { get; set; }
    public int? Number { get; set; }
    public string Status { get; set; } = string.Empty;
    /// <summary>[商品台帳] の 商品名（商品ｺｰﾄﾞで JOIN）</summary>
    public string ProductName { get; set; } = string.Empty;
}
