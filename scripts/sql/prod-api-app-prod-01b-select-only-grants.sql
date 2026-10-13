/*
  prod-api-app-prod-01b-select-only-grants.sql
  PURPOSE: Reference only — Model B (no db_datareader; GRANT SELECT per table).
  NOT recommended as default. Do not run unless you deliberately choose Model B
  instead of Model A in prod-api-app-prod-01-create.sql.

  Assumes USER api_app_prod already exists and is NOT in db_datareader.
  Password / LOGIN creation: use 01-create.sql without the db_datareader line,
  then run this file.

  sqlcmd -S oomiyaSV1,1433 -d OOMIYADB -E -f 65001 -i scripts\sql\prod-api-app-prod-01b-select-only-grants.sql
*/

SET NOCOUNT ON;
USE [OOMIYADB];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'api_app_prod')
BEGIN
    RAISERROR('User api_app_prod does not exist. Create LOGIN/USER first.', 16, 1);
    RETURN;
END;
GO

-- SELECT for current GET + write pre-checks (Controllers as of 2026-09-29)
GRANT SELECT ON [dbo].[担当者台帳] TO [api_app_prod];
GRANT SELECT ON [dbo].[ICタグ台帳] TO [api_app_prod];
GRANT SELECT ON [dbo].[商品台帳] TO [api_app_prod];
GRANT SELECT ON [dbo].[商品区分マスター] TO [api_app_prod];
GRANT SELECT ON [dbo].[受付台帳] TO [api_app_prod];
GRANT SELECT ON [dbo].[受付明細] TO [api_app_prod];
GRANT SELECT ON [dbo].[顧客台帳] TO [api_app_prod];
GRANT SELECT ON [dbo].[現場台帳] TO [api_app_prod];
GRANT SELECT ON [dbo].[期限台帳] TO [api_app_prod];
GRANT SELECT ON [dbo].[用件台帳] TO [api_app_prod];
GRANT SELECT ON [dbo].[単位台帳] TO [api_app_prod];
GRANT SELECT ON [dbo].[tag_table3] TO [api_app_prod];
GRANT SELECT ON [dbo].[tag_table4] TO [api_app_prod]; -- optional; GET unused today

PRINT 'Model B SELECT grants applied (reference). Remember write GRANTs from 01-create.sql separately.';
GO
