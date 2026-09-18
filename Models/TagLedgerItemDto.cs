namespace TagReaderApi.Models;

/// <summary>
/// [ICタグ台帳] の tag_id2・商品ｺｰﾄﾞ・番号（アプリ日次キャッシュ用）。
/// </summary>
public class TagLedgerItemDto
{
    public string TagId2 { get; set; } = string.Empty;
    public int? ProductCode { get; set; }
    public int? Number { get; set; }
}
