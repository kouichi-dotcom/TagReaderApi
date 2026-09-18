namespace TagReaderApi.Models;

/// <summary>
/// 在庫確認の区分グリッド用。[商品区分マスター] の1行。
/// </summary>
public class ProductCategoryDto
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
}
