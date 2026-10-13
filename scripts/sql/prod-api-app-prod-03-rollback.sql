/*
  prod-api-app-prod-03-rollback.sql
  PURPOSE: Remove api_app_prod USER + LOGIN. Does NOT touch api_readonly / sa / data rows.

  Only run if intentionally rolling back the create script.

  sqlcmd -S oomiyaSV1,1433 -d master -E -f 65001 -i scripts\sql\prod-api-app-prod-03-rollback.sql
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

USE [OOMIYADB];
GO

IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'api_app_prod')
BEGIN
    -- Drop role memberships first (safe if already gone)
    IF IS_ROLEMEMBER(N'db_datareader', N'api_app_prod') = 1
        ALTER ROLE [db_datareader] DROP MEMBER [api_app_prod];

    IF IS_ROLEMEMBER(N'db_datawriter', N'api_app_prod') = 1
        ALTER ROLE [db_datawriter] DROP MEMBER [api_app_prod];

    DROP USER [api_app_prod];
    PRINT 'Dropped USER api_app_prod from OOMIYADB';
END
ELSE
    PRINT 'USER api_app_prod not found in OOMIYADB (skip)';
GO

USE [master];
GO

IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'api_app_prod')
BEGIN
    DROP LOGIN [api_app_prod];
    PRINT 'Dropped LOGIN api_app_prod';
END
ELSE
    PRINT 'LOGIN api_app_prod not found (skip)';
GO

PRINT 'Rollback done. Confirm api_readonly still exists and is unchanged.';
GO
