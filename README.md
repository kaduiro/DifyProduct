# AInews_TechIntelligence

Difyワークフローベースの**IT技術全般の自動情報収集・分析・配信システム**。

月・水・金の午前7時（JST）に自動実行され、一次情報を中心に多角的にIT技術のトレンドを収集し、開発者向けのインテリジェンスレポートをSlackに配信する。

## バージョン履歴

| バージョン | ファイル名 | 主な変更 |
|-----------|-----------|---------|
| v6 | AInews_TechIntelligence_v6.yml | 初期版。Tavily検索のみ、AIトピック限定 |
| v7 | AInews_TechIntelligence_v7.yml | RSS 10ソース + arXiv API追加（一次情報直接取得） |
| v8 | AInews_TechIntelligence_v8.yml | GitHub Releases 12リポ + Tavily一次情報限定検索追加、Gemini対応 |
| v9 | AInews_TechIntelligence_v9.yml | ノード順序変更（DB保存→Slack送信）、execution_log、連続失敗検知、エスカレーション通知 |
| v10 | AInews_TechIntelligence_v10.yml | trigger-schedule導入（外部依存排除）、topic廃止→IT技術全般10カテゴリ、ソース大幅拡充 |

## v10 アーキテクチャ

### トリガー

- Difyネイティブの `trigger-schedule` ノード
- 月・水・金 07:00 JST に自動実行
- 外部スケジューラ（GitHub Actions等）不要

### 情報ソース（5系統・計74ソース）

#### A. RSSフィード（22ソース、全て一次情報）

| カテゴリ | ソース |
|---------|--------|
| AI/ML | OpenAI Blog, Anthropic, Google AI Blog, Meta AI, Hugging Face, LangChain |
| クラウド | AWS Blog, Google Cloud, Azure Blog |
| フロントエンド | Vercel Blog, Next.js Blog, Vue.js Blog |
| インフラ/DevOps | Cloudflare, Kubernetes Blog, Docker Blog |
| 言語 | Rust Blog, Go Blog |
| データ | PostgreSQL News, Supabase Blog |
| モバイル | Android Developers |
| 標準 | Chrome Developers |
| その他 | GitHub Changelog |

#### B. arXiv API（7カテゴリ、最新30論文）

- cs.AI（人工知能）
- cs.LG（機械学習）
- cs.CL（計算言語学）
- cs.SE（ソフトウェア工学）
- cs.CR（暗号セキュリティ）
- cs.DC（分散コンピューティング）
- cs.PL（プログラミング言語）

#### C. GitHub Releases API（24リポジトリ、全て一次情報）

| カテゴリ | リポジトリ |
|---------|-----------|
| AI/ML | dify, ollama, llama.cpp, openai-python, langchain, llama_index, autogen, transformers, vllm, litellm, open-webui, ComfyUI |
| Frontend | next.js, svelte, tailwindcss |
| Languages | deno, bun, rust |
| Infra | terraform, kubernetes, compose, grafana |
| Mobile | flutter |
| Data | supabase |

#### D. Tavily一次情報限定検索（8クエリ、ドメイン限定）

1. AI/LLMリリース
2. クラウドインフラ更新
3. 開発ツール/SDK
4. セキュリティ脆弱性
5. フロントエンドフレームワーク
6. Kubernetes/DevOps
7. プログラミング言語リリース
8. モバイル開発

#### E. Tavily汎用検索（12クエリ、LLM自動生成）

10カテゴリ + ウォッチリスト1 + 変動スポット1

### 10カテゴリ

1. AI/ML/LLM
2. フロントエンド/UI
3. バックエンド/API
4. インフラ/クラウド/DevOps
5. セキュリティ
6. データベース/データエンジニアリング
7. モバイル/クロスプラットフォーム
8. プログラミング言語/ランタイム
9. Web標準/プロトコル/OSS動向
10. IT業界動向/規制

### 情報フィルタリング（4段階）

1. **ドメイン信頼度スコアリング** - 117ドメイン、7カテゴリ
2. **ハッシュベース重複排除** - SHA-256
3. **差分検知** - NEW/UPDATE判定
4. **憶測・未確認情報の検出**

### LLM分析（Gemini 2.0 Flash × 4箇所）

1. 検索戦略立案（12クエリ自動生成）
2. クエリ最適化（3層キーワード展開）
3. クエリJSON解析
4. カテゴリ分類+実務インパクト分析（レポート生成）

### レポート構成

1. 変化ハイライト（3行）
2. 定点観測（10カテゴリ × 2-4件）
3. 今週のスポットライト（急浮上テーマ1件）
4. ウォッチリスト進捗
5. 今週の発掘（新興技術1件）

### 配信

- Slack Block Kit形式
- DB保存完了後にSlack送信（データ整合性保護）

### データ永続化（Supabase 5テーブル）

| テーブル | 用途 |
|---------|------|
| deliveries | 配信履歴 |
| article_hashes | 記事重複検知用ハッシュ |
| watch_entities | 技術ウォッチリスト |
| domain_trust | ドメイン信頼度マスタ（117ドメイン） |
| execution_log | 実行履歴・障害検知 |

### 運用監視

- execution_log記録
- 連続失敗検知（3回連続で発火）
- エスカレーション通知（Slack緊急アラート）

### エラーハンドリング

- 全HTTPノードにリトライ設定（2-3回）
- 全イテレーションにcontinue-on-error
- 各パーサーにフォールバック（エラー時は空リスト返却）

## セットアップ手順

### 前提条件

- Dify v1.10.0 以上
- Supabase アカウント
- Slack Incoming Webhook
- Google（Gemini）APIキー（Difyに設定済み）
- Tavilyアカウント（Difyプラグインとして設定済み）

### Step 1: Supabase テーブル作成

Supabase SQL Editor で以下を順番に実行する。

```sql
-- 1. 4テーブル作成
sql/create_tables.sql

-- 2. 95ドメイン登録
sql/seed_domain_trust.sql

-- 3. 追加22ドメイン登録
sql/seed_domain_trust_v2.sql

-- 4. 実行ログテーブル作成
sql/create_execution_log.sql
```

### Step 2: Dify ワークフローインポート

1. Difyダッシュボード → スタジオ → DSLをインポート
2. `AInews_TechIntelligence_v10.yml` をアップロード
3. 環境変数を設定:
   - `SUPABASE_URL`: Supabase Project URL
   - `SUPABASE_ANON_KEY`: Supabase Anonymous Key
   - `SLACK_WEBHOOK_URL`: Slack Incoming Webhook URL

### Step 3: プラグイン確認

- `langgenius/google`（Gemini）プラグインがインストール済みか確認
- `langgenius/tavily` プラグインがインストール済みか確認
- 各プラグインにAPIキーが設定済みか確認

### Step 4: Publish

ワークフローを Publish する。スケジュールが自動有効化される。

### Step 5: 動作確認

- Dify UIからテスト実行
- Slackにレポートが配信されることを確認
- Supabase の `deliveries` / `article_hashes` / `execution_log` にレコードが作成されることを確認

## ファイル構成

```
dify_product/
├── AInews_TechIntelligence_v6.yml    # 初期版
├── AInews_TechIntelligence_v7.yml    # RSS+arXiv追加
├── AInews_TechIntelligence_v8.yml    # GitHub+Tavily一次情報+Gemini
├── AInews_TechIntelligence_v9.yml    # エラーハンドリング強化
├── AInews_TechIntelligence_v10.yml   # trigger-schedule+IT全般10カテゴリ ← 最新
├── sql/
│   ├── create_tables.sql             # テーブル定義（4テーブル）
│   ├── seed_domain_trust.sql         # ドメイン信頼度シード（95件）
│   ├── seed_domain_trust_v2.sql      # 追加ドメインシード（22件）
│   └── create_execution_log.sql      # 実行ログテーブル+ビュー+関数
├── docs/
│   └── error_handling_design.md      # エラーハンドリング設計書
├── supabase/functions/
│   └── health-check/index.ts         # ヘルスチェックEdge Function
└── README.md                         # 本ファイル
```

## 運用

### 自動実行スケジュール

| 曜日 | 時刻 | 対象期間 |
|------|------|---------|
| 月曜 | 07:00 JST | 金→月の3日分 |
| 水曜 | 07:00 JST | 月→水の2日分 |
| 金曜 | 07:00 JST | 水→金の2日分 |

### 週次チェックリスト

- [ ] Slackに月/水/金のレポートが3通届いているか
- [ ] Supabase execution_log に `status="completed"` が3件あるか
- [ ] エスカレーション通知が来ていないか

### 確認用SQL

```sql
-- 最新の配信履歴
SELECT delivery_date, date_range, diff_summary->>'new_count' AS new_count
FROM deliveries ORDER BY delivery_date DESC LIMIT 5;

-- 実行ログ確認
SELECT execution_date, status, total_articles_after_filter
FROM execution_log ORDER BY execution_date DESC LIMIT 5;

-- ドメイン信頼度分布
SELECT category, COUNT(*) AS cnt, AVG(trust_score) AS avg_score
FROM domain_trust GROUP BY category ORDER BY avg_score DESC;
```

### トラブルシューティング

| 症状 | 原因 | 対処 |
|------|------|------|
| レポートが届かない | スケジュール未有効 | ワークフローをPublish済みか確認 |
| Supabase 404エラー | テーブル名不一致 | `create_tables.sql` を再実行 |
| RSS取得失敗 | フィードURL変更 | RSSソースリスト生成ノードのURLを確認・更新 |
| LLMエラー | APIキー期限切れ | DifyのGemini APIキーを確認 |
| エスカレーション通知 | 3回連続失敗 | `execution_log` で失敗原因を確認 |

## v10の設計上の工夫

### 一次情報への徹底的なこだわり

本システムの最大の特徴は、**二次情報（Qiita/Zenn/SNSまとめ等）を排除し、一次情報を優先する設計**にある。

- **RSS直接購読**: 企業公式ブログ22本を直接取得し、メディアの解釈を介さず原文を入手
- **GitHub Releases API**: 24リポジトリの公式リリースノートを直接取得。CHANGELOGやコミットログレベルの粒度で変更を追跡
- **arXiv API**: 論文プレプリントを7カテゴリで直接取得。メディア報道より数日〜数週間早い段階で技術動向を捕捉
- **Tavily `include_domains` 指定**: Web検索でも一次情報ドメインに限定した8クエリを別系統で実行し、汎用検索の二次情報混入リスクを補完
- **ドメイン信頼度スコアリング**: 117ドメインを7段階で評価（official:10 〜 secondary_jp:2）。trust_score 3未満の情報を自動除外することで、収集後も品質を担保

### 5系統並列取得による網羅性と耐障害性

情報ソースを5系統に分離し、初期化ノードから**全系統を並列実行**する設計を採用。

```
初期化 → ┬─ RSS 22本（並列3）
         ├─ arXiv API
         ├─ GitHub Releases 24本（並列3）
         ├─ Tavily一次情報限定 8クエリ（並列2）
         └─ Tavily汎用検索 12クエリ（並列2）
```

- **網羅性**: 単一ソース依存を排除。Tavilyが障害でもRSS/arXiv/GitHubの一次情報でレポート生成可能
- **耐障害性**: 全イテレーションに `continue-on-error` を設定。22本のRSSのうち数本が失敗しても残りで処理を継続
- **レート制限対策**: 各ループ内に1秒のsleepを挿入し、API制限に抵触しない設計

### topic変数廃止による情報収集の拡大

v9まではtopic変数（デフォルト "AI"）が全検索クエリに埋め込まれていたため、**フロントエンド、インフラ、セキュリティ、モバイル等のAI以外の技術領域が構造的に取得不可能**だった。

v10ではtopic変数を完全に廃止し、10カテゴリの固有キーワードで検索することで、IT技術全般を網羅する設計に変更。これにより：
- 検索クエリ数: 8 → 12（+50%）
- カバー領域: AI中心5カテゴリ → IT全般10カテゴリ（+100%）
- 最大収集件数: 約126件 → 約214件（+70%）

### DB保存先行によるデータ整合性保護

v8以前はSlack送信後にDB保存を行っていたため、**DB保存失敗時に次回の差分検知が破綻**するリスクがあった。

v9以降ではノード順序を「DB保存 → Slack送信」に変更：

```
v8以前: LLM分析 → Slack送信 → DB保存 → End
v9以降: LLM分析 → DB保存 → Slack送信 → End
```

これにより、DB保存が完了した状態でのみSlack配信が行われ、配信履歴と記事ハッシュの整合性が保証される。

### 4段階フィルタリングパイプライン

大量の収集データ（最大214件）から高品質な情報のみを抽出するために、4段階のフィルタリングを適用：

1. **ドメイン信頼度フィルタ**: 117ドメインのスコアで低品質ソースを除外（trust_score < 3を排除）
2. **ハッシュベース重複排除**: タイトル正規化+ドメインのSHA-256ハッシュでクラスタリング。複数ソースで報じられた記事は信頼度最高のものを代表として選出
3. **差分検知**: 前回配信タイトルとの照合でNEW/UPDATEを自動判定。既報の記事には「続報」ラベルを付与
4. **憶測検出**: 日英10パターンの正規表現で未確認情報を検出し、`⚠️未確認` ラベルを自動付与

### 自律的な障害検知・エスカレーション

ワークフロー自体が自身の健全性を監視する仕組みを内蔵：

1. **execution_log記録**: 毎回の実行結果（各ノードのHTTPステータス、記事数、所要時間）をSupabaseに記録
2. **連続失敗検知**: 直近3件のexecution_logを参照し、3回連続で失敗/部分失敗が続いた場合にエスカレーションを発火
3. **エスカレーション通知**: Slackに緊急アラート（Block Kit形式）を送信。通常のレポート配信チャンネルに「連続障害アラート」として目立つ形で通知

### trigger-schedule による外部依存の完全排除

v9まではGitHub Actionsでcronスケジュール → Dify APIキック → streamingレスポンスパースという外部依存チェーンが必要だった。v10ではDifyネイティブの `trigger-schedule` ノードを採用し：

- GitHub Actionsリポジトリが不要
- APIキー管理が不要
- blockingモードの100秒タイムアウト問題が根本解消
- Publishするだけでスケジュールが自動有効化

---

## 出力結果サンプル

### Slackレポート出力例

以下は実際にSlackに配信されるレポートの構成例：

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

AI/IT テックインテリジェンス 2026年03月19日〜2026年03月21日
前回から: 🆕 NEW 18件 / 🔄 UPDATE 4件 / 📊 合計22件

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔥 変化ハイライト

• 🆕[NEW] Google、Gemini 2.5 Pro をリリース — 100万トークンのコンテキストウィンドウ
• 🆕[NEW] Kubernetes 1.33 リリース — Sidecar Containers が GA に昇格
• 🔄[UPDATE] Rust 1.86 安定版リリース — trait upcasting が安定化

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📡 定点観測

*1. AI/ML/LLM*

• 🆕[NEW] *Gemini 2.5 Pro リリース*（2026-03-20）
  何が起きた: Googleが思考モデルGemini 2.5 Proを発表。100万トークン対応
  誰に効く: ML, BE, CTO
  試すべきこと: <https://aistudio.google.com|AI Studio> で無料トライアルを実行

• 🆕[NEW] *Anthropic Claude 4.5 Opus パフォーマンス改善*（2026-03-19）
  何が起きた: Claude 4.5 Opusのレイテンシが30%改善、バッチAPI対応
  誰に効く: BE, ML
  試すべきこと: <https://docs.anthropic.com|公式ドキュメント> でバッチAPI仕様を確認

*2. フロントエンド/UI*

• 🆕[NEW] *Next.js 15.3 リリース*（2026-03-20）
  何が起きた: Turbopackが本番ビルドで安定版に昇格、ビルド速度50%向上
  誰に効く: FE
  試すべきこと: `npx create-next-app@latest` で新規プロジェクトを作成し検証

• 🆕[NEW] *Svelte 5.2 — 新しいリアクティビティAPI*（2026-03-21）
  何が起きた: $derived.byを導入、より直感的な派生状態の定義が可能に
  誰に効く: FE
  試すべきこと: <https://svelte.dev/docs|公式ドキュメント> で$derived.byの使い方を確認

*3. バックエンド/API*
  ...（省略）

*4. インフラ/クラウド/DevOps*

• 🆕[NEW] *Kubernetes 1.33 リリース*（2026-03-19）
  何が起きた: Sidecar ContainersがGAに昇格、Pod Lifecycle改善
  誰に効く: Infra
  試すべきこと: `kubectl version` で現行バージョンを確認し、アップグレード計画を策定

*5. セキュリティ*

• 🆕[NEW] *CVE-2026-XXXX: OpenSSL重要度High*（2026-03-20）
  何が起きた: OpenSSL 3.x系にメモリ破壊の脆弱性、パッチ3.2.4リリース
  誰に効く: Infra, BE
  試すべきこと: `openssl version` で影響確認、3.2.4へ即時アップデート

*6〜10. （データベース、モバイル、言語、Web標準、IT業界動向）*
  ...（省略）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔮 今週のスポットライト

*WebAssembly Component Model 1.0*
W3Cが正式勧告。言語間の相互運用性が飛躍的に向上し...
  ...（詳細解説）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📌 ウォッチリスト進捗

• [Dify] (12週目) ↗️上昇
  進展: v1.10.1リリース。trigger-schedule の安定性改善
• [LangChain] (8週目) →安定
  進展: 大きな変更なし。LangGraphのドキュメント拡充
  ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🌱 今週の発掘

*Biome v2.0*
ESLint + Prettierの代替として急成長中のRust製ツールチェイン...
GitHub Stars: 16.2k（前月比+2.1k）
  ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🤖 Powered by Dify + Gemini | 自動生成レポート
```

### レポートの読み方

| 記号 | 意味 |
|------|------|
| 🆕[NEW] | 今回初めて検出された情報 |
| 🔄[UPDATE] | 前回配信にも含まれていた情報の続報 |
| 📌[WATCH] | ウォッチリストに登録済みの技術 |
| ⚠️ | 未確認情報・憶測を含む可能性あり |
| ↗️ / → / ↘️ | ウォッチリスト技術の勢い（上昇/安定/下降） |

### 対象ロール略称

| 略称 | 対象 |
|------|------|
| BE | バックエンドエンジニア |
| FE | フロントエンドエンジニア |
| ML | MLエンジニア |
| Infra | DevOps/SRE |
| PM | プロダクトマネージャー |
| CTO | 技術選定者 |

## 技術スタック

- **Dify** v1.10.0+（ワークフローエンジン）
- **Gemini 2.0 Flash**（LLM分析）
- **Tavily**（Web検索）
- **Supabase / PostgreSQL**（データ永続化）
- **Slack**（配信）
