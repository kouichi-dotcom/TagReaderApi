# API エンドポイント一覧

TagReaderApi が提供する問い合わせ先の総覧。詳細仕様は各個別ドキュメントを参照。

記録日: 2026-09-29（tag-ledger 登録系・environment 応答・アプリ対応を反映）

---

## ベース URL

| 環境 | App Service | ベース URL |
|------|-------------|------------|
| ローカル | （自機） | `http://localhost:5262` |
| Azure **staging（テスト）** | `ohmiyakoki-tagapp-api` | `https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net` |
| Azure **prod（本番・読取版）** | `ohmiyakoki-tagapp-api-prod` | `https://ohmiyakoki-tagapp-api-prod-gsdcabb4gzbzcyaw.japanwest-01.azurewebsites.net` |

確認時は `{ベースURL}` + 下表のパス。例（staging）:  
`https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net/api/environment`

本番の基準設定（`Production` / `readOnly=true` / `API_READ_ONLY=true`）は [本番読取版_基準設定.md](./本番読取版_基準設定.md)。

> **注意:** `https://ohmiyakoki-tagapp-api.azurewebsites.net` や短い既定ドメインはこの App Service には割り当てられていません。必ず上の `japanwest-01` 付き URL を使う。

> **注意:** DB を使う API は、Azure 側の接続文字列と Hybrid Connection（等）が揃うまで失敗する。  
> DB 不要でデプロイ確認できるのは **`GET /api/environment`**（とサンプルの `/weatherforecast`）のみ。

> **注意:** 書き込みゲートは次の順で判定する（いずれも middleware、コントローラ到達前）。
> 1. `API_READ_ONLY=true` → すべての変更系メソッドを **403**（個別 `Writes__*` が true でも禁止）
> 2. `API_READ_ONLY=false` のとき、対象パスのみ個別設定を確認（未設定・不正値は **false**＝禁止）
>    - `Writes__ProductUpdates` → `POST /api/product-updates`
>    - `Writes__TagLedger` → `POST /api/products/tag-ledger`
>    - `Writes__LinkTags` → `POST /api/reception-slips/{receptionNo}/link-tags`
> 3. コントローラ側の `Database:ReadOnly=true` は従来どおり **409**（middleware 通過後）
>
> `/api/environment` の `readOnly` は **`Database:ReadOnly` のみ**（`API_READ_ONLY` / `Writes__*` は反映しない）。

---

## エンドポイント総覧

| メソッド | パス | 主なクエリ / Body | DB | 用途 | 詳細 |
|----------|------|-------------------|----|------|------|
| GET | `/api/environment` | なし | 不要 | 環境名・DB種別・readOnly | （Program.cs） |
| GET | `/weatherforecast` | なし | 不要 | テンプレートのサンプル | （Program.cs） |
| GET | `/api/employees` | `code`（必須） | 要 | 担当者 1 件 | [担当者API.md](./担当者API.md) |
| GET | `/api/employees/all` | `minCode`, `maxCode` | 要 | 担当者一括（キャッシュ用） | [担当者API.md](./担当者API.md) |
| GET | `/api/products` | `epc`（必須） | 要 | EPC → 商品情報 | [商品API.md](./商品API.md) |
| GET | `/api/products/random` | `count`（省略時 5） | 要 | ランダム N 件（シミュレート） | [商品API.md](./商品API.md) |
| GET | `/api/products/catalog` | なし | 要 | 現存商品一覧（キャッシュ） | [商品API.md](./商品API.md) |
| GET | `/api/products/tag-ledger` | なし | 要 | ICタグ台帳一括（廃棄除外） | [商品API.md](./商品API.md) |
| GET | `/api/products/tag-ledger/next-number` | `code`（必須） | 要 | 商品コードの次番号（MAX+1） | （ProductsController） |
| POST | `/api/products/tag-ledger` | JSON Body（`epc`, `product_code`, `number` / `auto_number`, `user_name` 等） | 要 | ICタグ台帳へ新規登録 | （ProductsController） |
| GET | `/api/products/by-code` | `code`（必須） | 要 | 商品コード 1 件 | [商品API.md](./商品API.md) |
| GET | `/api/products/categories` | なし | 要 | 商品区分一覧（在庫画面） | （ProductsController） |
| GET | `/api/products/inventory` | `categoryId`（任意）, `q`（任意・商品名/コード部分一致） | 要 | 在庫集計一覧 | （ProductsController） |
| GET | `/api/products/inventory/units` | `code`（必須） | 要 | 商品コードごとの個体一覧 | （ProductsController） |
| GET | `/api/reception-slips` | `date`, `assigneeCode`, `unassignedOnly`, `random`, `subjects`, `excludeSubjects`, `limit`, `offset` | 要 | 受付伝票一覧（ページング可）。確認=0・期日の直近1ヶ月・キャンセル用件除外 | [受付台帳API.md](./受付台帳API.md) |
| POST | `/api/reception-slips/{receptionNo}/link-tags` | JSON Body（`user_id`, `link_mode`, `items[]`） | 要 | 伝票へタグ紐付け（引取・来店(返品)／交換納品・交換返品／配達・来店(納品)） | [受付伝票タグ紐付けAPI.md](./受付伝票タグ紐付けAPI.md) |
| POST | `/api/product-updates` | JSON Body（`epc`, `read_at`, `changes.status` 等） | 要 | ステータス更新（`status` は文字列・最大30文字） | [商品更新API.md](./商品更新API.md) |

### 計画中（未実装）

| メソッド | パス | 主なクエリ / Body | DB | 用途 | 詳細 |
|----------|------|-------------------|----|------|------|
| GET | `/api/tag-readers/all` | なし | 要 | タグリーダー一覧（キャッシュ） | [タグリーダー管理.md](./タグリーダー管理.md) |
| GET | `/api/tag-readers` | `address`（必須） | 要 | タグリーダー 1 件 | [タグリーダー管理.md](./タグリーダー管理.md) |
| POST | `/api/tag-readers` | JSON Body | 要 | タグリーダー新規登録 | [タグリーダー管理.md](./タグリーダー管理.md) |
| PUT | `/api/tag-readers/{id}` | JSON Body | 要 | 管理番号・表示名の更新 | [タグリーダー管理.md](./タグリーダー管理.md) |

---

## Azure × テストDB 接続確認リンク

ベース URL（この App Service 専用）:

`https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net`

ブラウザで開いて JSON が返れば OK。**200 + JSON** なら API 稼働（DB 系は SQL 接続も成功）。

### ① API のみ（DB 不要）

| 確認内容 | リンク |
|----------|--------|
| 環境名 | [GET /api/environment](https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net/api/environment) |
| サンプル JSON | [GET /weatherforecast](https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net/weatherforecast) |

### ② DB 接続確認（おすすめ順）

| 確認内容 | リンク | 期待する結果 |
|----------|--------|--------------|
| 担当者一覧（軽い） | [GET /api/employees/all?minCode=1&maxCode=10](https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net/api/employees/all?minCode=1&maxCode=10) | `[{"employeeCode":3,...}, ...]` |
| 担当者 1 件 | [GET /api/employees?code=3](https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net/api/employees?code=3) | `{"employeeCode":3,"employeeName":"..."}` |
| 商品ランダム | [GET /api/products/random?count=2](https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net/api/products/random?count=2) | タグ情報の配列 |
| 伝票ランダム | [GET /api/reception-slips?random=true](https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net/api/reception-slips?random=true) | 伝票の配列（最大 10 件） |
| 商品区分 | [GET /api/products/categories](https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net/api/products/categories) | 区分マスタの配列 |
| 商品カタログ | [GET /api/products/catalog](https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net/api/products/catalog) | 商品一覧（やや大きい） |
| タグ台帳 | [GET /api/products/tag-ledger](https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net/api/products/tag-ledger) | タグ台帳（約 6,000 件・大きい） |
| 次番号 | [GET /api/products/tag-ledger/next-number?code=1234](https://ohmiyakoki-tagapp-api-aygbh8h5gsh4gwc0.japanwest-01.azurewebsites.net/api/products/tag-ledger/next-number?code=1234) | `{"productCode":1234,"nextNumber":N}` |

> **`/api/employees?code=1` が 404 になる理由**  
> 接続失敗ではなく、**担当者コード 1 がテスト DB に存在しない**ため。  
> テスト DB には 3, 4, 8, 10 などがあるので **`code=3`** を使う。

> **500 / タイムアウト** → Hybrid Connection・接続文字列・HCM・SQL 認証を疑う。  
> **404（employees 1件）** → その code が DB に無いだけのことが多い。

---

## Azure / ローカルでの確認例（パス一覧）

### DB なし

```text
GET {ベースURL}/api/environment
→ {"environment":"...","databaseKind":"Local|Test|Production","readOnly":true|false} など
```

### DB あり（参照）

```text
GET {ベースURL}/api/employees/all?minCode=1&maxCode=10
GET {ベースURL}/api/employees?code=3
GET {ベースURL}/api/products?epc={EPC}
GET {ベースURL}/api/products/random?count=3
GET {ベースURL}/api/products/catalog
GET {ベースURL}/api/products/tag-ledger
GET {ベースURL}/api/products/tag-ledger/next-number?code=1234
GET {ベースURL}/api/products/by-code?code=1234
GET {ベースURL}/api/products/categories
GET {ベースURL}/api/products/inventory
GET {ベースURL}/api/products/inventory?categoryId=3
GET {ベースURL}/api/products/inventory?q=ハンマー
GET {ベースURL}/api/products/inventory/units?code=1234
GET {ベースURL}/api/reception-slips?assigneeCode=3
GET {ベースURL}/api/reception-slips?unassignedOnly=true
GET {ベースURL}/api/reception-slips?random=true
```

### DB あり（更新・読取専用時は不可）

```http
POST {ベースURL}/api/product-updates
Content-Type: application/json

{
  "epc": "（tag_id2）",
  "read_at": "2026-09-29T12:00:00",
  "changes": { "status": "ＯＫ" },
  "user_id": "1"
}
```

```http
POST {ベースURL}/api/products/tag-ledger
Content-Type: application/json

{
  "epc": "（tag_id2）",
  "product_code": 1234,
  "auto_number": true,
  "user_name": "山田"
}
```

```http
POST {ベースURL}/api/reception-slips/{receptionNo}/link-tags
Content-Type: application/json

{
  "user_id": "51",
  "items": [
    { "epc": "（tag_id2）", "product_code": "1234" }
  ]
}
```

---

## アプリ側（tag_reader_app）の呼び出し対応

実体は `lib/api/api_client.dart`（環境取得のみ `lib/config/api_config.dart`）。

| ApiClient / 関数 | 呼び出す API |
|------------------|--------------|
| `fetchAndCacheApiEnvironment` | `GET /api/environment` |
| `fetchEmployee` | `GET /api/employees` |
| `fetchEmployeesInRange` | `GET /api/employees/all` |
| `fetchProduct` | `GET /api/products` |
| `fetchRandomProducts` | `GET /api/products/random` |
| `fetchProductCatalog` | `GET /api/products/catalog` |
| `fetchTagLedger` | `GET /api/products/tag-ledger` |
| `fetchNextTagNumber` | `GET /api/products/tag-ledger/next-number` |
| `registerTagLedger` | `POST /api/products/tag-ledger` |
| `fetchProductByCode` | `GET /api/products/by-code` |
| `fetchProductCategories` | `GET /api/products/categories` |
| `fetchInventory` | `GET /api/products/inventory` |
| `fetchInventoryUnits` | `GET /api/products/inventory/units` |
| `fetchReceptionSlips` | `GET /api/reception-slips` |
| `submitSlipTagLinks` | `POST /api/reception-slips/{receptionNo}/link-tags` |
| `submitProductUpdate` | `POST /api/product-updates` |

ベース URL は `lib/config/api_config.dart` の `kApiBaseUrl`。接続先は `FLAVOR`（staging / prod）または明示 `APP_ENV=local` のみで決まる（未指定時に本番へフォールバックしない）。

---

## 個別ドキュメント

| ドキュメント | 内容 |
|--------------|------|
| [担当者API.md](./担当者API.md) | employees |
| [商品API.md](./商品API.md) | products（EPC・catalog・tag-ledger GET・by-code 等） |
| [受付台帳API.md](./受付台帳API.md) | reception-slips（一覧） |
| [受付伝票タグ紐付けAPI.md](./受付伝票タグ紐付けAPI.md) | link-tags |
| [商品更新API.md](./商品更新API.md) | product-updates |
| [タグリーダー管理.md](./タグリーダー管理.md) | タグリーダー管理（**計画・未実装**） |
| [本番読取版_基準設定.md](./本番読取版_基準設定.md) | 本番 readOnly 基準・Azure 設定 |
| [ローカル起動.md](./ローカル起動.md) | ローカルでの起動方法 |
| [API公開のチェックリスト.md](./API公開のチェックリスト.md) | Azure 公開手順 |
