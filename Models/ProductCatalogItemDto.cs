namespace TagReaderApi.Models;

/// <summary>
/// [商品台帳] の 商品コード・商品名 のみを返す用（一括・1件取得）。
/// </summary>
public class ProductCatalogItemDto
{
    public int ProductCode { get; set; }
    public string ProductName { get; set; } = string.Empty;
}
