namespace TagReaderApi.Models;

/// <summary>
/// 受付台帳の1件。顧客台帳・現場台帳・期限台帳を参照して表示用に展開。受付明細を含む。
/// </summary>
public class ReceptionSlipDto
{
    /// <summary>受付番号（テキストそのまま）</summary>
    public string ReceptionNo { get; set; } = string.Empty;

    /// <summary>用件</summary>
    public string Subject { get; set; } = string.Empty;

    /// <summary>顧客id → [顧客台帳] 顧客コードに紐づく顧客名</summary>
    public string CustomerName { get; set; } = string.Empty;

    /// <summary>顧客名（その他）</summary>
    public string? CustomerNameOther { get; set; }

    /// <summary>現場名 → [現場台帳] 現場コード・現場名</summary>
    public string SiteName { get; set; } = string.Empty;

    /// <summary>現場名（その他）</summary>
    public string? SiteNameOther { get; set; }

    /// <summary>期日</summary>
    public DateTime? DueDate { get; set; }

    /// <summary>期限コード → [期限台帳] の期限</summary>
    public string? DeadlineName { get; set; }

    /// <summary>期限２</summary>
    public string? Deadline2 { get; set; }

    /// <summary>メモ</summary>
    public string? Memo { get; set; }

    /// <summary>受付日時</summary>
    public DateTime? ReceptionAt { get; set; }

    /// <summary>処理者（配達担当者）の担当者コード等</summary>
    public string? HandlerCode { get; set; }

    /// <summary>処理者（担当者コード）に対応する担当者氏名。[担当者台帳] から取得</summary>
    public string? HandlerName { get; set; }

    /// <summary>受付明細（受付番号が同じもの。商品名・台数・単位名を表示用に展開）</summary>
    public List<ReceptionDetailItemDto> Details { get; set; } = new();
}
