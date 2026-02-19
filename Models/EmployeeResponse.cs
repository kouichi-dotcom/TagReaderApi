namespace TagReaderApi.Models;

/// <summary>
/// [担当者台帳] の担当者コード・担当者氏名を返す用。
/// </summary>
public class EmployeeResponse
{
    public int EmployeeCode { get; set; }
    public string EmployeeName { get; set; } = string.Empty;
}
