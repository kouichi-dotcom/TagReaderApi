namespace TagReaderApi.Models;

/// <summary>
/// アプリ在庫確認画面用。[商品台帳] と [ICタグ台帳] の集計を JSON で返す。
/// </summary>
public class InventoryItemDto
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int? CategoryId { get; set; }
    public string Category { get; set; } = string.Empty;
    public string Sku { get; set; } = string.Empty;
    public string ImageUrl { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public int CountOk { get; set; }
    public int CountStorage { get; set; }
    public int CountCleaning { get; set; }
    public int CountMaintenance { get; set; }
    public int CountRented { get; set; }
    public double? BaseFee { get; set; }
    public double? DailyPrice { get; set; }
    public double? MonthlyPrice { get; set; }
}
