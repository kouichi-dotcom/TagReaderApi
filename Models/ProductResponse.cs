namespace TagReaderApi.Models;

/// <summary>
/// [ICタグ台帳] + [商品台帳] の tag_id2, 商品ｺｰﾄﾞ, 番号, tag_mode2, 商品名, 保管場所コード を返す用。
/// </summary>
public class ProductResponse
{
    public string TagId2 { get; set; } = string.Empty;
    public int? ProductCode { get; set; }
    public int? Number { get; set; }
    public string Status { get; set; } = string.Empty;
    /// <summary>[商品台帳] の 商品名（商品ｺｰﾄﾞで JOIN）</summary>
    public string ProductName { get; set; } = string.Empty;
    /// <summary>[ICタグ台帳].[保管場所コード]（1=本社, 2=山川, 3=東風平, 4=友寄）</summary>
    public int? StorageLocationCode { get; set; }
}
