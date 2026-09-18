# 商品 API

[商品台帳] および [ICタグ台帳] を利用する API。

## エンドポイント一覧

| メソッド | パス | 説明 |
|----------|------|------|
| GET | `/api/products` | EPC をキーに商品情報取得（ICタグ台帳 + 商品台帳） |
| GET | `/api/products/random` | ランダムに N 件取得（読み取りシミュレート用） |
| GET | `/api/products/catalog` | 商品台帳から現存商品一覧を一括取得（キャッシュ用） |
| GET | `/api/products/tag-ledger` | ICタグ台帳から tag_id2・商品コード・番号を一括取得（日次キャッシュ用・廃棄除外） |
| GET | `/api/products/by-code` | 商品コードで 1 件取得（オンデマンド用） |

---

## GET /api/products/tag-ledger（タグ台帳一括）

[ICタグ台帳] の `tag_id2`, `商品ｺｰﾄﾞ`, `番号` を一括で返す。`tag_mode2 = 廃棄` は除外。アプリは **1日の初回起動**で取得して端末にキャッシュする。

### レスポンス

- **200** … `[{ "tagId2": string, "productCode": number|null, "number": number|null }, ...]`

---

## GET /api/products/catalog（一括取得）

[商品台帳] のうち **[現存する商品] = 1** のレコードの [商品コード], [商品名] を一括で返す。アプリの初回起動時キャッシュ用。

### レスポンス

- **200** … `[{ "productCode": number, "productName": string }, ...]`（商品コード昇順）

---

## GET /api/products/by-code（1件取得）

商品コードをキーに [商品台帳] から 1 件取得。キャッシュに無い場合のオンデマンド用。

### クエリパラメータ

| パラメータ | 型 | 必須 | 説明 |
|------------|-----|------|------|
| `code` | int | ○ | 商品コード |

### レスポンス

- **200** … `{ "productCode": number, "productName": string }`
- **400** … code 未指定
- **404** … 該当する商品が存在しない
