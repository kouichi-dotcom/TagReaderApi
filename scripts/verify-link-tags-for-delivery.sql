-- =============================================================================
-- 受付伝票タグ紐付け → 納品転記の前提条件チェック（テストDB用）
-- =============================================================================
-- 使い方:
--   1. SSMS のツールバーで DB を [OOMIYADB] にする（master だと失敗する）
--   2. 下の @受付番号 を、アプリで送信した受付番号に書き換える
--   3. このスクリプト全体を実行する
--
-- 既存 Reception.cs が納品転記時に読む条件（要約）:
--   tag_table3.受付番号 = 対象受付
--   ICタグ台帳.tag_mode2 = N'貸出中'
--   tag_id2 で結合し、商品コードで受付明細と突合 → 納品明細に「番号」を書く
--   転記前は complete = 0（C# DataTable 上の「済=0」に相当）
--
-- アプリ送信 API が書くもの（用件=<配達> / 来店(納品) など納品モード）:
--   [ICタグ台帳].tag_mode2 / updated
--   [tag_table3] 受付番号, tag_id2, tag_mode(=納品), s_code, mark, complete, 印刷, read_time
-- 書かないもの:
--   納品伝票 / 納品明細（転記後に初めて番号が入る）
--
-- ※用件「来店(納品)」も「<配達>」と同じ書き込み（納品モード）
-- 検証 SQL（引取・来店(返品)用）: scripts/verify-link-tags-for-pickup.sql
-- =============================================================================

USE [OOMIYADB];
GO

DECLARE @受付番号 int = 404146;  -- ★ ここを書き換える

-- ---------------------------------------------------------------------------
-- 1) Reception.cs と同じ結合（転記が拾う行）
--    → 1行以上あれば「転記可能なタグがある」
-- ---------------------------------------------------------------------------
SELECT
    t.ID,
    t.[受付番号],
    LTRIM(RTRIM(t.tag_id2)) AS tag_id2,
    t.tag_mode          AS tag_table3_tag_mode,
    t.s_code,
    t.read_time,
    CAST(t.mark AS int)     AS mark,
    CAST(t.complete AS int) AS complete,   -- 転記前は 0 であること
    CAST(t.[印刷] AS int)   AS [印刷],
    d.[商品ｺｰﾄﾞ]            AS 商品コード,
    d.tag_mode2,                          -- 必須: N'貸出中'
    d.[番号],                             -- 納品明細に載る番号の元
    d.updated
FROM [dbo].[tag_table3] AS t
INNER JOIN [dbo].[ICタグ台帳] AS d
    ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
WHERE t.[受付番号] = @受付番号
  AND d.tag_mode2 = N'貸出中'
ORDER BY t.ID;

-- ---------------------------------------------------------------------------
-- 2) 合否サマリ（1行で見る）
-- ---------------------------------------------------------------------------
SELECT
    @受付番号 AS 受付番号,
    (
        SELECT COUNT(*)
        FROM [dbo].[tag_table3] t
        INNER JOIN [dbo].[ICタグ台帳] d
            ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
        WHERE t.[受付番号] = @受付番号
          AND d.tag_mode2 = N'貸出中'
    ) AS 転記対象件数_貸出中,
    (
        SELECT COUNT(*)
        FROM [dbo].[tag_table3] t
        INNER JOIN [dbo].[ICタグ台帳] d
            ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
        WHERE t.[受付番号] = @受付番号
          AND d.tag_mode2 = N'貸出中'
          AND ISNULL(t.complete, 0) = 0
    ) AS 未転記件数_complete0,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM [dbo].[tag_table3] t
            INNER JOIN [dbo].[ICタグ台帳] d
                ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
            WHERE t.[受付番号] = @受付番号
              AND d.tag_mode2 = N'貸出中'
              AND ISNULL(t.complete, 0) = 0
        )
        THEN N'OK: 納品転記が番号を拾える条件を満たす'
        ELSE N'NG: 条件未達（tag_table3 無し / 貸出中でない / 既に complete=1）'
    END AS 判定;

-- ---------------------------------------------------------------------------
-- 3) カラム単位の期待値チェック（送信直後）
-- ---------------------------------------------------------------------------
SELECT
    t.ID,
    LTRIM(RTRIM(t.tag_id2)) AS tag_id2,
    CASE WHEN t.[受付番号] = @受付番号 THEN N'OK' ELSE N'NG' END AS chk_受付番号,
    CASE WHEN ISNULL(t.complete, 0) = 0 THEN N'OK' ELSE N'NG(既に転記済?)' END AS chk_complete_0,
    CASE WHEN ISNULL(t.mark, 0) = 0 THEN N'OK' ELSE N'NG' END AS chk_mark_0,
    CASE WHEN ISNULL(t.[印刷], 0) = 0 THEN N'OK' ELSE N'NG' END AS chk_印刷_0,
    CASE WHEN t.tag_mode = N'納品' THEN N'OK' ELSE N'要確認' END AS chk_tag_table3_tag_mode,
    CASE WHEN d.tag_mode2 = N'貸出中' THEN N'OK' ELSE N'NG' END AS chk_台帳_貸出中,
    CASE WHEN d.[番号] IS NOT NULL THEN N'OK' ELSE N'NG(番号なし)' END AS chk_番号あり,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM [dbo].[受付明細] m
            WHERE m.[受付番号] = @受付番号
              AND m.[商品コード] = d.[商品ｺｰﾄﾞ]
        )
        THEN N'OK'
        ELSE N'警告: 受付明細に商品コードなし'
    END AS chk_受付明細に商品あり,
    d.[商品ｺｰﾄﾞ] AS 商品コード,
    d.[番号],
    d.tag_mode2,
    t.s_code,
    t.read_time,
    d.updated
FROM [dbo].[tag_table3] AS t
INNER JOIN [dbo].[ICタグ台帳] AS d
    ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
WHERE t.[受付番号] = @受付番号
ORDER BY t.ID;

-- ---------------------------------------------------------------------------
-- 4) 問題の切り分け（条件を満たさない行）
-- ---------------------------------------------------------------------------
-- 4a) この受付の tag_table3 はあるが、台帳が貸出中でない
SELECT
    N'台帳が貸出中でない' AS 問題,
    t.ID,
    LTRIM(RTRIM(t.tag_id2)) AS tag_id2,
    d.tag_mode2,
    d.[番号]
FROM [dbo].[tag_table3] AS t
LEFT JOIN [dbo].[ICタグ台帳] AS d
    ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
WHERE t.[受付番号] = @受付番号
  AND (d.tag_id2 IS NULL OR ISNULL(d.tag_mode2, N'') <> N'貸出中');

-- 4b) 貸出中だが complete=1（転記済み扱い → 再転記では使われにくい）
SELECT
    N'complete=1 のため未使用扱いの可能性' AS 問題,
    t.ID,
    LTRIM(RTRIM(t.tag_id2)) AS tag_id2,
    CAST(t.complete AS int) AS complete,
    d.[番号]
FROM [dbo].[tag_table3] AS t
INNER JOIN [dbo].[ICタグ台帳] AS d
    ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
WHERE t.[受付番号] = @受付番号
  AND d.tag_mode2 = N'貸出中'
  AND ISNULL(t.complete, 0) = 1;

-- ---------------------------------------------------------------------------
-- 5) 参考: 受付明細との突合イメージ（転記ロジックの商品コード突合）
-- ---------------------------------------------------------------------------
SELECT
    m.[商品コード] AS 受付明細_商品コード,
    p.[商品名],
    m.[台数] AS 受付_台数,
    COUNT(x.tag_id2) AS 紐付タグ件数_貸出中未転記,
    STRING_AGG(CONVERT(nvarchar(20), x.[番号]), N',') AS 番号一覧
FROM [dbo].[受付明細] AS m
LEFT JOIN [dbo].[商品台帳] AS p ON p.[商品コード] = m.[商品コード]
LEFT JOIN (
    SELECT
        LTRIM(RTRIM(t.tag_id2)) AS tag_id2,
        d.[商品ｺｰﾄﾞ] AS 商品コード,
        d.[番号]
    FROM [dbo].[tag_table3] AS t
    INNER JOIN [dbo].[ICタグ台帳] AS d
        ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
    WHERE t.[受付番号] = @受付番号
      AND d.tag_mode2 = N'貸出中'
      AND ISNULL(t.complete, 0) = 0
) AS x ON x.商品コード = m.[商品コード]
WHERE m.[受付番号] = @受付番号
GROUP BY m.[商品コード], p.[商品名], m.[台数]
ORDER BY m.[商品コード];
