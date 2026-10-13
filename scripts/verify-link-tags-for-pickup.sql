-- =============================================================================
-- 受付伝票タグ紐付け → 引取（返品）記録チェック（テストDB用）
-- =============================================================================
-- 使い方:
--   1. SSMS のツールバーで DB を [OOMIYADB] にする（master だと失敗する）
--   2. 下の @受付番号 を、アプリで送信した受付番号に書き換える
--   3. このスクリプト全体を実行する
--
-- 引取 / 来店(返品) の link-tags API が書くもの:
--   [ICタグ台帳].tag_mode2 = N'在庫'
--   [tag_table3].tag_mode = N'返品'
--   [tag_table3].complete = 1
--   tag_table3.受付番号, tag_id2, s_code, mark=0, 印刷=0, read_time
--   [納品明細].[返却] = 1（顧客コード＋現場コード＋tag_id=EPC 一致の既存行のみ。他列は変更しない）
--
-- ※用件「来店(返品)」も「引取」と同じ書き込み（返品モード）
-- 検証 SQL（配達・来店(納品)用）: scripts/verify-link-tags-for-delivery.sql
-- =============================================================================

USE [OOMIYADB];
GO

DECLARE @受付番号 int = 404146;  -- ★ ここを書き換える

-- ---------------------------------------------------------------------------
-- 1) 引取送信後の行（在庫 + 返品 + complete=1）
-- ---------------------------------------------------------------------------
SELECT
    t.ID,
    t.[受付番号],
    LTRIM(RTRIM(t.tag_id2)) AS tag_id2,
    t.tag_mode          AS tag_table3_tag_mode,
    t.s_code,
    t.read_time,
    CAST(t.mark AS int)     AS mark,
    CAST(t.complete AS int) AS complete,   -- 引取は 1
    CAST(t.[印刷] AS int)   AS [印刷],
    d.[商品ｺｰﾄﾞ]            AS 商品コード,
    d.tag_mode2,                          -- 必須: N'在庫'
    d.[番号],
    d.updated
FROM [dbo].[tag_table3] AS t
INNER JOIN [dbo].[ICタグ台帳] AS d
    ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
WHERE t.[受付番号] = @受付番号
  AND d.tag_mode2 = N'在庫'
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
          AND d.tag_mode2 = N'在庫'
    ) AS 件数_在庫,
    (
        SELECT COUNT(*)
        FROM [dbo].[tag_table3] t
        INNER JOIN [dbo].[ICタグ台帳] d
            ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
        WHERE t.[受付番号] = @受付番号
          AND d.tag_mode2 = N'在庫'
          AND t.tag_mode = N'返品'
          AND ISNULL(t.complete, 0) = 1
    ) AS 件数_返品_complete1,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM [dbo].[tag_table3] t
            INNER JOIN [dbo].[ICタグ台帳] d
                ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
            WHERE t.[受付番号] = @受付番号
              AND d.tag_mode2 = N'在庫'
              AND ISNULL(t.complete, 0) = 1
              AND t.tag_mode = N'返品'
        )
        THEN N'OK: 引取（返品/在庫/complete=1）の条件を満たす'
        ELSE N'NG: 条件未達（tag_table3 無し / 在庫でない / tag_mode≠返品 / complete≠1）'
    END AS 判定;

-- ---------------------------------------------------------------------------
-- 3) カラム単位の期待値チェック（送信直後）
-- ---------------------------------------------------------------------------
SELECT
    t.ID,
    LTRIM(RTRIM(t.tag_id2)) AS tag_id2,
    CASE WHEN t.[受付番号] = @受付番号 THEN N'OK' ELSE N'NG' END AS chk_受付番号,
    CASE WHEN ISNULL(t.complete, 0) = 1 THEN N'OK' ELSE N'NG(complete≠1)' END AS chk_complete_1,
    CASE WHEN ISNULL(t.mark, 0) = 0 THEN N'OK' ELSE N'NG' END AS chk_mark_0,
    CASE WHEN ISNULL(t.[印刷], 0) = 0 THEN N'OK' ELSE N'NG' END AS chk_印刷_0,
    CASE WHEN t.tag_mode = N'返品' THEN N'OK' ELSE N'要確認' END AS chk_tag_table3_tag_mode,
    CASE WHEN d.tag_mode2 = N'在庫' THEN N'OK' ELSE N'NG' END AS chk_台帳_在庫,
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
-- 4a) この受付の tag_table3 はあるが、台帳が在庫でない
SELECT
    N'台帳が在庫でない' AS 問題,
    t.ID,
    LTRIM(RTRIM(t.tag_id2)) AS tag_id2,
    d.tag_mode2,
    d.[番号]
FROM [dbo].[tag_table3] AS t
LEFT JOIN [dbo].[ICタグ台帳] AS d
    ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
WHERE t.[受付番号] = @受付番号
  AND (d.tag_id2 IS NULL OR ISNULL(d.tag_mode2, N'') <> N'在庫');

-- 4b) tag_mode が返品でない
SELECT
    N'tag_mode が返品でない' AS 問題,
    t.ID,
    LTRIM(RTRIM(t.tag_id2)) AS tag_id2,
    t.tag_mode,
    d.tag_mode2
FROM [dbo].[tag_table3] AS t
INNER JOIN [dbo].[ICタグ台帳] AS d
    ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
WHERE t.[受付番号] = @受付番号
  AND ISNULL(t.tag_mode, N'') <> N'返品';

-- 4c) complete が 1 でない
SELECT
    N'complete≠1' AS 問題,
    t.ID,
    LTRIM(RTRIM(t.tag_id2)) AS tag_id2,
    CAST(t.complete AS int) AS complete,
    d.[番号]
FROM [dbo].[tag_table3] AS t
INNER JOIN [dbo].[ICタグ台帳] AS d
    ON LTRIM(RTRIM(t.tag_id2)) = LTRIM(RTRIM(d.tag_id2))
WHERE t.[受付番号] = @受付番号
  AND d.tag_mode2 = N'在庫'
  AND ISNULL(t.complete, 0) <> 1;

-- ---------------------------------------------------------------------------
-- 5) 納品明細の返却記録（顧客コード＋現場コード＋tag_id）
-- ---------------------------------------------------------------------------
SELECT
    LTRIM(RTRIM(t.tag_id2)) AS tag_id2,
    r.[顧客コード],
    r.[現場コード],
    n.id AS 納品明細id,
    n.[伝票番号],
    CAST(n.[返却] AS int) AS [返却],
    CASE
        WHEN n.id IS NULL THEN N'NG: 納品明細なし（API は警告のみ）'
        WHEN ISNULL(n.[返却], 0) = 1 THEN N'OK: 返却=1'
        ELSE N'NG: 返却≠1'
    END AS chk_納品明細_返却
FROM [dbo].[tag_table3] AS t
INNER JOIN [dbo].[受付台帳] AS r ON r.[受付番号] = t.[受付番号]
LEFT JOIN [dbo].[納品明細] AS n
    ON n.[顧客コード] = r.[顧客コード]
   AND (
        (r.[現場コード] IS NULL AND n.[現場コード] IS NULL)
        OR n.[現場コード] = r.[現場コード]
       )
   AND LTRIM(RTRIM(n.[tag_id])) = LTRIM(RTRIM(t.tag_id2))
WHERE t.[受付番号] = @受付番号
ORDER BY t.tag_id2, n.id;

-- ---------------------------------------------------------------------------
-- 6) 参考: 受付明細との突合イメージ
-- ---------------------------------------------------------------------------
SELECT
    m.[商品コード] AS 受付明細_商品コード,
    p.[商品名],
    m.[台数] AS 受付_台数,
    COUNT(x.tag_id2) AS 紐付タグ件数_在庫_complete1,
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
      AND d.tag_mode2 = N'在庫'
      AND ISNULL(t.complete, 0) = 1
) AS x ON x.商品コード = m.[商品コード]
WHERE m.[受付番号] = @受付番号
GROUP BY m.[商品コード], p.[商品名], m.[台数]
ORDER BY m.[商品コード];
