/*
  prod-api-app-prod-04-grant-delivery-detail-update.sql
  PURPOSE: Additive grant for existing api_app_prod — UPDATE on [納品明細]
           (link-tags pickup / visit-return: set [返却]=1 only).
  Safe to re-run. Does not create LOGIN/USER.

  sqlcmd -S oomiyaSV1,1433 -d OOMIYADB -E -f 65001 ^
    -i scripts\sql\prod-api-app-prod-04-grant-delivery-detail-update.sql
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

GRANT UPDATE ON [dbo].[納品明細] TO [api_app_prod];
DENY  INSERT, DELETE ON [dbo].[納品明細] TO [api_app_prod];

PRINT 'Granted UPDATE (and DENY INSERT/DELETE) on dbo.納品明細 for api_app_prod';
GO
