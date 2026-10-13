# 本番 SQL：`api_app_prod` 最小権限設計（案・未実行）

**状態**: 設計のみ。**本番 DB には未適用**  
**前提**: 現行 `api_readonly`（`db_datareader`）は変更しない  
**Login / User 候補名**: `api_app_prod`

---

## 推奨案

**SELECT は `db_datareader`、書き込みは対象 3 テーブルへのオブジェクト権限のみ（`db_datawriter` は使わない）。**

| 観点 | 案 A: `db_datareader` + 書き込み GRANT | 案 B: 必要テーブルだけ `GRANT SELECT` |
|------|----------------------------------------|----------------------------------------|
| GET 全通の確かさ | 高い（現行 `api_readonly` と同型） | 一覧漏れで GET が突然 500 になりやすい |
| 最小権限（読取） | 他テーブルも SELECT 可（広い） | 読取も狭い |
| 最小権限（書込） | 狭い（同じ） | 狭い（同じ） |
| メンテ | GET 追加時に権限変更ほぼ不要 | Controller JOIN 追加のたび GRANT 更新が必要 |
| 本プロジェクトの段階解放 | App Settings（`Writes__*`）と併用しやすい | 同上 |

**推奨理由**: いまの脅威モデルで重要なのは「誤って全表へ INSERT/UPDATE/DELETE できないこと」。読取は既に `api_readonly` が `db_datareader` で運用できている。書き込みだけ 3 表に限定するのが費用対効果が高い。案 B は将来の GET 追加・JOIN 追加で壊れやすい。

案 B を採る場合の SELECT 候補（現行 Controller 実調査）は後述「SELECT 対象一覧」。

---

## 書き込み権限（両案共通）

| テーブル | INSERT | UPDATE | DELETE |
|----------|--------|--------|--------|
| `[dbo].[ICタグ台帳]` | ○ | ○ | ×（GRANT しない。必要なら DENY） |
| `[dbo].[tag_table3]` | ○ | × | ○ |
| `[dbo].[tag_table4]` | ○ | × | × |
| `[dbo].[納品明細]` | × | ○（`[返却]` のみ想定） | × |

- **付与しない**: `db_datawriter`、DDL（CREATE/ALTER/DROP TABLE 等）、他テーブルへの DML
- **変更しない**: `sa`、`api_readonly`

---

## 更新 API ↔ 必要権限 対応表

| API | 主な操作 | 必要な権限 |
|-----|----------|------------|
| `POST /api/product-updates` | `[ICタグ台帳]` UPDATE（`tag_mode2`/`保管場所コード`/`updated`）、`[tag_table4]` INSERT | IC: UPDATE（+SELECT）、tag_table4: INSERT（+SELECT 不要だが reader で可） |
| `POST /api/products/tag-ledger` | `[商品台帳]` SELECT、`[ICタグ台帳]` SELECT（UPDLOCK）+ INSERT | 商品台帳: SELECT、IC: SELECT + INSERT（番号採番時は SELECT のみで UPDLOCK） |
| `POST .../link-tags` | 受付系 SELECT、`[ICタグ台帳]` SELECT+UPDATE、`[tag_table3]` SELECT + DELETE(complete=0) + INSERT、返品時 `[納品明細]` UPDATE(`[返却]`) | IC: SELECT+UPDATE、tag_table3: SELECT+DELETE+INSERT、納品明細: UPDATE、受付/用件/明細等: SELECT |

GET 系（`employees` / `products` / `reception-slips` 等）はすべて **SELECT のみ**。案 A なら `db_datareader` で充足。

---

## SELECT 対象一覧（案 B 用・現行コード）

`EmployeesController` / `ProductsController` / `ReceptionSlipsController` が参照する読取テーブル:

- `[dbo].[担当者台帳]`
- `[dbo].[ICタグ台帳]`
- `[dbo].[商品台帳]`
- `[dbo].[商品区分マスター]`
- `[dbo].[受付台帳]`
- `[dbo].[受付明細]`
- `[dbo].[顧客台帳]`
- `[dbo].[現場台帳]`
- `[dbo].[期限台帳]`
- `[dbo].[用件台帳]`
- `[dbo].[単位台帳]`
- `[dbo].[tag_table3]`（link-tags の complete 判定）
- （将来 GET で触る可能性）`[dbo].[tag_table4]` は現状 GET 未使用だが、案 A なら reader に含まれる

---

## パスワードの扱い（Git / SQL ファイルに書かない）

1. 強いパスワードをパスワードマネージャ等で生成（リポジトリ外）
2. 実行時のみ SQLCMD 変数で渡す:

```bat
sqlcmd -S oomiyaSV1,1433 -d master -E -i scripts\sql\prod-api-app-prod-01-create.sql -v ApiAppProdPassword="****"
```

3. Azure 接続文字列は Portal / Key Vault にだけ設定（ソース・Git・本ドキュメントにパスワードを書かない）
4. スクリプト内は `$(ApiAppProdPassword)` のみ。平文の DEFAULT 値は置かない

---

## 適用スクリプト（未実行）

| ファイル | 用途 |
|----------|------|
| [`scripts/sql/prod-api-app-prod-01-create.sql`](../scripts/sql/prod-api-app-prod-01-create.sql) | CREATE LOGIN/USER・ロール・GRANT（推奨案 A） |
| [`scripts/sql/prod-api-app-prod-02-verify.sql`](../scripts/sql/prod-api-app-prod-02-verify.sql) | 権限確認 |
| [`scripts/sql/prod-api-app-prod-03-rollback.sql`](../scripts/sql/prod-api-app-prod-03-rollback.sql) | ロールバック（USER/LOGIN DROP） |
| [`scripts/sql/prod-api-app-prod-04-grant-delivery-detail-update.sql`](../scripts/sql/prod-api-app-prod-04-grant-delivery-detail-update.sql) | 既存 api_app_prod への `[納品明細]` UPDATE 追加 GRANT |
| [`scripts/sql/prod-api-app-prod-01b-select-only-grants.sql`](../scripts/sql/prod-api-app-prod-01b-select-only-grants.sql) | 案 B 用 SELECT GRANT 一覧（参考・未推奨） |

**本番への適用は、別途明示的な承認後に行う。**

---

## 適用後の切替イメージ（参考・今回はやらない）

1. `api_app_prod` 作成・verify PASS  
2. staging / ローカルで同権限ユーザーを試す（任意）  
3. 本番 App Service の接続文字列を `api_app_prod` に切替（App Settings 変更は別タスク）  
4. 当面は `API_READ_ONLY=true` のまま GET 回帰  
5. その後 `Writes__*` を 1 本ずつ解放  

現行本番読取版の戻し先: [本番読取版_基準設定.md](./本番読取版_基準設定.md)
