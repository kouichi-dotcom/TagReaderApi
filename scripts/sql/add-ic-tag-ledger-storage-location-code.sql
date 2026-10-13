-- ICタグ台帳へ [保管場所コード] を追加（安全な冪追加）
-- 値: 1=本社, 2=山川, 3=東風平, 4=友寄
-- 既存行は NULL のまま（業務影響なし）
-- 実行先: ローカル / staging / 本番それぞれで必要時に実行

IF COL_LENGTH(N'dbo.ICタグ台帳', N'保管場所コード') IS NULL
BEGIN
    ALTER TABLE [dbo].[ICタグ台帳]
    ADD [保管場所コード] [int] NULL;

    PRINT N'Added column [ICタグ台帳].[保管場所コード] (int NULL).';
END
ELSE
BEGIN
    PRINT N'Column [ICタグ台帳].[保管場所コード] already exists. Skipped.';
END
GO
