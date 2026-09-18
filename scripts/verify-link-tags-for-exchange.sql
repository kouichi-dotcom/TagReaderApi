-- =============================================================================
-- 受付伝票タグ紐付け → 用件「交換」（交換納品 / 交換返品）の記録チェック
-- =============================================================================
-- 使い方:
--   1. SSMS のツールバーで DB を [OOMIYADB] にする（master だと失敗する）
--   2. 下の @受付番号 を、アプリで送信した受付番号に書き換える
--   3. このスクリプト全体を実行する
--
-- 期待値:
--   交換納品: ICタグ台帳.tag_mode2 = N'貸出中'
--             tag_table3.tag_mode = N'交換納品', complete = 0, mark = 0, 印刷 = 0
--   交換返品: ICタグ台帳.tag_mode2 = N'整備中'
--             tag_table3.tag_mode = N'交換返品', complete = 1, mark = 0, 印刷 = 0
-- =============================================================================

USE [OOMIYADB];
GO

DECLARE @受付番号 int = 304698;  -- ★ ここを書き換える

-- ---------------------------------------------------------------------------
-- 1) 受付の用件が「交換」か
-- ---------------------------------------------------------------------------
SELECT
    r.[受付番号],
    ISNULL(p.[用件], N'') AS 用件,
    CASE WHEN ISNULL(p.[用件], N'') = N'交換' THEN N'OK' ELSE N'NG: 用件が交換ではない' END AS chk_用件
FROM [dbo].[受付台帳] r
LEFT JOIN [dbo].[用件台帳] p ON p.[用件コード] = r.[用件コード]
WHERE r.[受付番号] = @受付番号;

-- ---------------------------------------------------------------------------
-- 2) tag_table3 × ICタグ台帳（交換系の行）
-- ---------------------------------------------------------------------------
SELECT
    t.[受付番号],
    t.tag_id2,
    t.tag_mode          AS tag_table3_tag_mode,
    t.complete,
    t.mark,
    t.[印刷],
    t.s_code,
    t.read_time,
    d.tag_mode2,
    d.[番号],
    d.[商品ｺｰﾄﾞ],
    CASE
        WHEN t.tag_mode = N'交換納品' AND ISNULL(t.complete, 0) = 0 AND d.tag_mode2 = N'貸出中'
            THEN N'OK: 交換納品'
        WHEN t.tag_mode = N'交換返品' AND ISNULL(t.complete, 0) = 1 AND d.tag_mode2 = N'整備中'
            THEN N'OK: 交換返品'
        ELSE N'NG / 要確認'
    END AS chk
FROM [dbo].[tag_table3] t
INNER JOIN [dbo].[ICタグ台帳] d
    ON LTRIM(RTRIM(d.tag_id2)) = LTRIM(RTRIM(t.tag_id2))
WHERE t.[受付番号] = @受付番号
  AND t.tag_mode IN (N'交換納品', N'交換返品')
ORDER BY t.read_time DESC, t.tag_id2;

-- ---------------------------------------------------------------------------
-- 3) サマリ
-- ---------------------------------------------------------------------------
SELECT
    @受付番号 AS 受付番号,
    (SELECT COUNT(*) FROM [dbo].[tag_table3]
     WHERE [受付番号] = @受付番号 AND tag_mode = N'交換納品') AS cnt_交換納品,
    (SELECT COUNT(*) FROM [dbo].[tag_table3]
     WHERE [受付番号] = @受付番号 AND tag_mode = N'交換返品') AS cnt_交換返品,
    (SELECT COUNT(*)
     FROM [dbo].[tag_table3] t
     INNER JOIN [dbo].[ICタグ台帳] d
         ON LTRIM(RTRIM(d.tag_id2)) = LTRIM(RTRIM(t.tag_id2))
     WHERE t.[受付番号] = @受付番号
       AND t.tag_mode = N'交換納品'
       AND ISNULL(t.complete, 0) = 0
       AND ISNULL(t.mark, 0) = 0
       AND ISNULL(t.[印刷], 0) = 0
       AND d.tag_mode2 = N'貸出中') AS ok_交換納品,
    (SELECT COUNT(*)
     FROM [dbo].[tag_table3] t
     INNER JOIN [dbo].[ICタグ台帳] d
         ON LTRIM(RTRIM(d.tag_id2)) = LTRIM(RTRIM(t.tag_id2))
     WHERE t.[受付番号] = @受付番号
       AND t.tag_mode = N'交換返品'
       AND ISNULL(t.complete, 0) = 1
       AND ISNULL(t.mark, 0) = 0
       AND ISNULL(t.[印刷], 0) = 0
       AND d.tag_mode2 = N'整備中') AS ok_交換返品;
