/*
  prod-api-app-prod-01-create.sql
  PURPOSE: Create api_app_prod with minimal write grants (DESIGN ONLY until approved).
  DO NOT run against production without explicit approval.

  Recommended model (A):
    - db_datareader for SELECT
    - object-level INSERT/UPDATE/DELETE on 3 tables only
    - NO db_datawriter, NO DDL

  Password: pass via SQLCMD variable only (never commit secrets).

  Example (Windows auth to server; adjust auth as needed):
    sqlcmd -S oomiyaSV1,1433 -d master -E -f 65001 ^
      -i scripts\sql\prod-api-app-prod-01-create.sql ^
      -v ApiAppProdPassword="YOUR_PASSWORD_HERE"

  Leaves api_readonly / sa unchanged.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF UNICODE(N'$(ApiAppProdPassword)') = UNICODE(N'$')
   AND LEFT(N'$(ApiAppProdPassword)', 2) = N'$('
BEGIN
    RAISERROR('ApiAppProdPassword SQLCMD variable is required. Do not embed passwords in files.', 16, 1);
    RETURN;
END;

IF LEN(N'$(ApiAppProdPassword)') < 12
BEGIN
    RAISERROR('ApiAppProdPassword looks too short. Use a strong password from a password manager.', 16, 1);
    RETURN;
END;

---------------------------------------------------------------------------
-- 1) LOGIN (server scope)
---------------------------------------------------------------------------
USE [master];
GO

IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'api_app_prod')
BEGIN
    RAISERROR('Login api_app_prod already exists. Aborting to avoid overwrite.', 16, 1);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'api_app_prod')
BEGIN
    CREATE LOGIN [api_app_prod]
        WITH PASSWORD = '$(ApiAppProdPassword)',
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = OFF;
    PRINT 'Created LOGIN api_app_prod';
END;
GO

---------------------------------------------------------------------------
-- 2) USER in OOMIYADB
---------------------------------------------------------------------------
USE [OOMIYADB];
GO

IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'api_app_prod')
BEGIN
    RAISERROR('User api_app_prod already exists in OOMIYADB. Aborting.', 16, 1);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'api_app_prod')
BEGIN
    CREATE USER [api_app_prod] FOR LOGIN [api_app_prod];
    PRINT 'Created USER api_app_prod in OOMIYADB';
END;
GO

---------------------------------------------------------------------------
-- 3) Roles: reader only (no db_datawriter / no ddl_admin)
---------------------------------------------------------------------------
ALTER ROLE [db_datareader] ADD MEMBER [api_app_prod];
PRINT 'Added api_app_prod to db_datareader';
GO

---------------------------------------------------------------------------
-- 4) Write grants (object level) + DENY for forbidden DML
---------------------------------------------------------------------------
-- IC tag ledger: INSERT + UPDATE; DELETE forbidden
GRANT INSERT, UPDATE ON [dbo].[ICタグ台帳] TO [api_app_prod];
DENY  DELETE ON [dbo].[ICタグ台帳] TO [api_app_prod];

-- tag_table3: INSERT + DELETE; UPDATE forbidden
GRANT INSERT, DELETE ON [dbo].[tag_table3] TO [api_app_prod];
DENY  UPDATE ON [dbo].[tag_table3] TO [api_app_prod];

-- tag_table4: INSERT only; UPDATE/DELETE forbidden
GRANT INSERT ON [dbo].[tag_table4] TO [api_app_prod];
DENY  UPDATE, DELETE ON [dbo].[tag_table4] TO [api_app_prod];

-- 納品明細: UPDATE only（引取／来店(返品) の [返却]=1）。INSERT/DELETE forbidden
GRANT UPDATE ON [dbo].[納品明細] TO [api_app_prod];
DENY  INSERT, DELETE ON [dbo].[納品明細] TO [api_app_prod];

PRINT 'Granted/Denied object permissions for write tables';
GO

PRINT 'Done. Next: run prod-api-app-prod-02-verify.sql';
GO
