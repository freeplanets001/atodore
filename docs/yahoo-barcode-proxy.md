# Yahoo!ショッピング JAN検索 中継API

Yahoo! Client IDをiOSアプリに埋め込まないため、Cloudflare Workersなどのサーバー側でJAN検索を中継します。

## 構成

1. iOSアプリが `BarcodeLookupProxyURL?barcode=JANコード` を呼び出す
2. Workerが環境変数 `YAHOO_SHOPPING_CLIENT_ID` を使ってYahoo!ショッピングAPIを呼び出す
3. Workerが商品名候補だけをアプリに返す

## Cloudflare Workersでの設定

1. Cloudflare Workersで新しいWorkerを作成
2. `docs/yahoo-barcode-proxy-worker.js` の内容を貼り付け
3. Workerの環境変数に以下を設定
   - `YAHOO_SHOPPING_CLIENT_ID`
4. Workerをデプロイ
5. 発行されたURLを `atodore/Info.plist` の `BarcodeLookupProxyURL` に設定

例:

```xml
<key>BarcodeLookupProxyURL</key>
<string>https://your-worker-name.your-account.workers.dev/</string>
```

## 注意

- `シークレットID` はこの構成では使いません。
- iOSアプリにClient IDやSecretを直接入れると、逆解析で取り出される可能性があります。
- GitHubのpublic repositoryには実際のClient IDをcommitしないでください。
