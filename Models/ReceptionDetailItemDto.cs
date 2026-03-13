namespace TagReaderApi.Models;

/// <summary>
/// 受付明細の1行。商品コード→商品名、台数、単位コード→単位名。
/// </summary>
public class ReceptionDetailItemDto
{
    /// <summary>商品コード</summary>
    public int? ProductCode { get; set; }

    /// <summary>[商品台帳] から取得した商品名</summary>
    public string ProductName { get; set; } = string.Empty;

    /// <summary>台数（そのまま表示）</summary>
    public decimal? Quantity { get; set; }

    /// <summary>[単位台帳] から取得した単位名</summary>
    public string UnitName { get; set; } = string.Empty;
}
