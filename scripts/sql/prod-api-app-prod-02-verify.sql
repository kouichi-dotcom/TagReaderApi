/*
  prod-api-app-prod-02-verify.sql
  PURPOSE: Verify api_app_prod permissions (read-only checks; no DML on data).
  Safe to run after create. Does not change data or alter api_readonly.

  sqlcmd -S oomiyaSV1,1433 -d OOMIYADB -E -f 65001 -i scripts\sql\prod-api-app-prod-02-verify.sql
*/

SET NOCOUNT ON;
USE [OOMIYADB];
GO

PRINT '=== principals ===';
SELECT
    dp.name AS db_user,
    dp.type_desc,
    sp.name AS login_name
FROM sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp
    ON dp.sid = sp.sid
WHERE dp.name IN (N'api_app_prod', N'api_readonly');

PRINT '=== role membership ===';
SELECT
    r.name AS role_name,
    m.name AS member_name
FROM sys.database_role_members AS drm
INNER JOIN sys.database_principals AS r ON drm.role_principal_id = r.principal_id
INNER JOIN sys.database_principals AS m ON drm.member_principal_id = m.principal_id
WHERE m.name IN (N'api_app_prod', N'api_readonly')
ORDER BY m.name, r.name;

PRINT '=== expect: api_app_prod in db_datareader; NOT in db_datawriter / db_ddladmin / db_owner ===';

PRINT '=== effective object perms (HAS_PERMS_BY_NAME as api_app_prod) ===';
EXECUTE AS USER = N'api_app_prod';

SELECT
    obj AS object_name,
    HAS_PERMS_BY_NAME(obj, 'OBJECT', 'SELECT') AS can_select,
    HAS_PERMS_BY_NAME(obj, 'OBJECT', 'INSERT') AS can_insert,
    HAS_PERMS_BY_NAME(obj, 'OBJECT', 'UPDATE') AS can_update,
    HAS_PERMS_BY_NAME(obj, 'OBJECT', 'DELETE') AS can_delete
FROM (VALUES
    (N'dbo.ICタグ台帳'),
    (N'dbo.tag_table3'),
    (N'dbo.tag_table4'),
    (N'dbo.商品台帳'),
    (N'dbo.受付台帳'),
    (N'dbo.受付明細'),
    (N'dbo.担当者台帳'),
    (N'dbo.納品台帳'),
    (N'dbo.納品明細')
) AS t(obj);

REVERT;
GO

PRINT '=== expected matrix (api_app_prod) ===';
PRINT 'ICタグ台帳 : SELECT=1 INSERT=1 UPDATE=1 DELETE=0';
PRINT 'tag_table3  : SELECT=1 INSERT=1 UPDATE=0 DELETE=1';
PRINT 'tag_table4  : SELECT=1 INSERT=1 UPDATE=0 DELETE=0';
PRINT '納品明細   : SELECT=1 INSERT=0 UPDATE=1 DELETE=0';
PRINT '商品/受付/担当者/納品台帳 : SELECT=1 INSERT=0 UPDATE=0 DELETE=0';
PRINT 'api_readonly role membership must be unchanged (db_datareader only).';
GO
