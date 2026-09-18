namespace TagReaderApi.Models;

/// <summary>
/// 在庫確認: 同一商品コードに紐づく [ICタグ台帳] の1行（個体）。
/// </summary>
public class InventoryUnitRowDto
{
    public int? Number { get; set; }
    public string TagMode2 { get; set; } = string.Empty;
    public string Manufacturer { get; set; } = string.Empty;
    public string ModelType { get; set; } = string.Empty;
    public string Remarks { get; set; } = string.Empty;
    /// <summary>yyyy/MM/dd。DB が日付でない場合は文字列のまま返す。</summary>
    public string? AcquisitionDateYmd { get; set; }
}
