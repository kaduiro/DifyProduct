# 弱いシグナル検出システム 設計書

## 概要

「話題化前の弱いシグナル」を自動検出するDifyワークフロー。完成した記事ではなく、製品ローンチ前の断片的シグナルを拾い、早期にアラートする。

### 検出対象シグナル

| # | シグナル種別 | 情報源 | 検出方法 |
|---|-------------|--------|----------|
| 1 | GitHub star急伸 | GitHub Search API | HTTPリクエストノード |
| 2 | docsサイト新設 | Tavily検索 | Tavilyツールノード |
| 3 | changelog新機能追加 | Tavily検索 | Tavilyツールノード |
| 4 | pricing page公開 | Tavily検索 | Tavilyツールノード |
| 5 | waitlist/beta開始 | Tavily検索 | Tavilyツールノード |
| 6 | 採用ページ新カテゴリ | Tavily検索 | Tavilyツールノード |
| 7 | API reference公開 | Tavily検索 | Tavilyツールノード |
| 8 | Product Hunt掲載 | Tavily検索 | Tavilyツールノード |
| 9 | プレスリリース | Tavily検索 | Tavilyツールノード |

---

## Difyノード構成図

```
[Start]
  |
  v
[Code: 初期化・日付計算] ── date_from, signal_queries, github_queries を生成
  |
  +---> [並列分岐1: GitHub弱いシグナル検出]
  |       |
  |       v
  |     [Iteration: GitHub API呼び出しループ]
  |       |  (github_queries配列をイテレート)
  |       |
  |       +--[HTTP Request: GitHub Search API] ── 各クエリでリポジトリ検索
  |       |
  |       +--[Code: GitHubレスポンスパース] ── name, stars, created_at等を抽出
  |       |
  |       v
  |     [Code: GitHub結果統合・重複排除]
  |
  +---> [並列分岐2: Tavilyイベントベース検索]
  |       |
  |       v
  |     [Iteration: Tavily弱いシグナル検索ループ]
  |       |  (signal_queries配列をイテレート)
  |       |
  |       +--[Tool: Tavily Search] ── 各シグナルクエリで検索
  |       |
  |       +--[Code: Tavily結果パース] ── title, url, snippet, signal_type を抽出
  |       |
  |       v
  |     [Code: Tavily結果統合]
  |
  +---> [並列分岐3: Product Hunt検索]
          |
          v
        [Tool: Tavily Search] ── site:producthunt.com クエリ
          |
          v
        [Code: Product Hunt結果パース]
  |
  v
[Code: 全シグナル統合・スコアリング] ── 弱いシグナル評価スコア算出
  |
  v
[LLM: シグナル分析・レポート生成] ── スコア付きシグナルを自然言語でまとめる
  |
  v
[Code: Slack/LINE配信用フォーマット]
  |
  v
[HTTP Request: Slack Webhook送信]
  |
  v
[End]
```

---

## 1. HTTPリクエストノード設定（GitHub API用）

### ノード: 初期化・日付計算（Codeノード）

```python
def main() -> dict:
    from datetime import datetime, timedelta

    today = datetime.now()
    date_from = (today - timedelta(days=7)).strftime('%Y-%m-%d')

    github_queries = [
        {
            "url": f"https://api.github.com/search/repositories?q=topic:ai+created:>{date_from}+stars:>100&sort=stars&order=desc&per_page=15",
            "label": "AI全般 (stars>100)"
        },
        {
            "url": f"https://api.github.com/search/repositories?q=topic:llm+created:>{date_from}+stars:>50&sort=stars&order=desc&per_page=15",
            "label": "LLM (stars>50)"
        },
        {
            "url": f"https://api.github.com/search/repositories?q=topic:ai-agent+created:>{date_from}+stars:>30&sort=stars&order=desc&per_page=15",
            "label": "AIエージェント (stars>30)"
        },
        {
            "url": f"https://api.github.com/search/repositories?q=topic:developer-tools+created:>{date_from}+stars:>50&sort=stars&order=desc&per_page=15",
            "label": "開発者ツール (stars>50)"
        },
        {
            "url": f"https://api.github.com/search/repositories?q=topic:inference+created:>{date_from}+stars:>30&sort=stars&order=desc&per_page=15",
            "label": "推論エンジン (stars>30)"
        }
    ]

    signal_queries = [
        {
            "query": f'"API reference" OR "docs site" OR "getting started" (AI OR LLM OR agent) after:{date_from}',
            "signal_type": "docs_api_reference",
            "weight": 3
        },
        {
            "query": f'"waitlist" OR "early access" OR "beta" (AI OR "developer tool") after:{date_from}',
            "signal_type": "waitlist_beta",
            "weight": 4
        },
        {
            "query": f'"pricing" OR "free tier" OR "developer plan" (AI API OR inference) after:{date_from}',
            "signal_type": "pricing_launch",
            "weight": 4
        },
        {
            "query": f'"changelog" OR "release notes" OR "what\'s new" (AI OR LLM OR SDK) after:{date_from}',
            "signal_type": "changelog_release",
            "weight": 2
        },
        {
            "query": f'site:producthunt.com (AI OR "developer tool" OR LLM OR agent) after:{date_from}',
            "signal_type": "product_hunt",
            "weight": 5
        },
        {
            "query": f'"press release" OR "announces" (AI startup OR "AI platform" OR "LLM API") after:{date_from}',
            "signal_type": "press_release",
            "weight": 3
        },
        {
            "query": f'"hiring" OR "careers" OR "job opening" ("AI engineer" OR "ML engineer" OR "LLM") (startup OR "series A" OR "seed") after:{date_from}',
            "signal_type": "hiring_signal",
            "weight": 2
        }
    ]

    return {
        "date_from": date_from,
        "github_queries": github_queries,
        "signal_queries": signal_queries,
        "github_query_count": len(github_queries),
        "signal_query_count": len(signal_queries)
    }
```

### ノード: GitHub Search API HTTPリクエスト

Dify HTTPリクエストノードの設定:

```yaml
# Iterationノード内部に配置
github_api_request:
  type: http-request
  method: GET
  url: "{{#item.url#}}"
  headers:
    Accept: "application/vnd.github.v3+json"
    User-Agent: "DifyWeakSignalDetector"
  # 認証なし（10req/min）の場合はAuthorizationヘッダー不要
  # 認証あり（30req/min）の場合は以下を追加:
  # Authorization: "Bearer {{#env.GITHUB_TOKEN#}}"
  timeout:
    max_connect_timeout: 10
    max_read_timeout: 30
  retry:
    max_retries: 2
    retry_interval: 3000
```

**Iterationノードの設定:**
- イテレータ: `{{#init_node.github_queries#}}`
- 並列数: `1`（レートリミット対策、認証なしは10req/min）
- 各ループで `item.url` と `item.label` が参照可能

### ノード: GitHubレスポンスパース（Codeノード）

```python
def main(response_body: str, label: str) -> dict:
    import json

    try:
        data = json.loads(response_body)
        items = data.get("items", [])
        repos = []

        for item in items[:10]:
            repos.append({
                "name": item.get("name", ""),
                "full_name": item.get("full_name", ""),
                "description": item.get("description", "") or "",
                "stargazers_count": item.get("stargazers_count", 0),
                "created_at": item.get("created_at", ""),
                "html_url": item.get("html_url", ""),
                "language": item.get("language", ""),
                "topics": item.get("topics", []),
                "has_wiki": item.get("has_wiki", False),
                "has_pages": item.get("has_pages", False),
                "homepage": item.get("homepage", "") or "",
                "open_issues_count": item.get("open_issues_count", 0),
                "forks_count": item.get("forks_count", 0),
                "search_label": label
            })

        return {
            "repos": repos,
            "count": len(repos),
            "error": ""
        }
    except Exception as e:
        return {
            "repos": [],
            "count": 0,
            "error": str(e)
        }
```

---

## 2. Tavily弱いシグナル用クエリリスト

Iterationノードで `signal_queries` 配列をイテレートし、各要素の `query` フィールドをTavilyツールに渡す。

### クエリ一覧（signal_type別）

| # | signal_type | クエリ | 重み | 狙い |
|---|------------|--------|------|------|
| 1 | docs_api_reference | `"API reference" OR "docs site" OR "getting started" (AI OR LLM OR agent) after:YYYY-MM-DD` | 3 | API公開/docsサイト新設を検出 |
| 2 | waitlist_beta | `"waitlist" OR "early access" OR "beta" (AI OR "developer tool") after:YYYY-MM-DD` | 4 | ウェイトリスト/ベータ開始を検出 |
| 3 | pricing_launch | `"pricing" OR "free tier" OR "developer plan" (AI API OR inference) after:YYYY-MM-DD` | 4 | 料金ページ公開=ローンチ間近を検出 |
| 4 | changelog_release | `"changelog" OR "release notes" OR "what's new" (AI OR LLM OR SDK) after:YYYY-MM-DD` | 2 | 新機能追加・リリースを検出 |
| 5 | product_hunt | `site:producthunt.com (AI OR "developer tool" OR LLM OR agent) after:YYYY-MM-DD` | 5 | Product Hunt掲載を検出 |
| 6 | press_release | `"press release" OR "announces" (AI startup OR "AI platform" OR "LLM API") after:YYYY-MM-DD` | 3 | プレスリリースを検出 |
| 7 | hiring_signal | `"hiring" OR "careers" OR "job opening" ("AI engineer" OR "ML engineer") (startup OR "series A") after:YYYY-MM-DD` | 2 | 採用活動の変化を検出 |

### Tavilyツールノードの設定

```yaml
tavily_signal_search:
  type: tool
  tool_name: tavily_search
  tool_parameters:
    query: "{{#item.query#}}"
    search_depth: "basic"
    max_results: 5
    include_answer: false
```

### ノード: Tavily結果パース（Codeノード）

```python
def main(tavily_result: str, signal_type: str, weight: int) -> dict:
    import json

    try:
        results = json.loads(tavily_result) if isinstance(tavily_result, str) else tavily_result
        items = results if isinstance(results, list) else results.get("results", [])

        signals = []
        for item in items:
            signals.append({
                "title": item.get("title", ""),
                "url": item.get("url", ""),
                "snippet": item.get("content", "")[:300],
                "signal_type": signal_type,
                "weight": weight,
                "source": "tavily"
            })

        return {
            "signals": signals,
            "count": len(signals)
        }
    except Exception as e:
        return {
            "signals": [],
            "count": 0,
            "error": str(e)
        }
```

---

## 3. 弱いシグナル評価スコアリング（Pythonコード）

### ノード: 全シグナル統合・スコアリング（Codeノード）

```python
def main(github_repos: list, tavily_signals: list) -> dict:
    """
    全ソースからのシグナルを統合し、エンティティ単位でスコアリングする。

    スコアリング基準:
    - GitHub stars増加率（週次）: 高starほど高スコア
    - 複数シグナルの同時出現: docs + pricing + API = 製品ローンチ間近 -> ボーナス
    - シグナル種別ごとの重み付け

    入力:
    - github_repos: GitHubイテレーションの出力（リストのリスト）
    - tavily_signals: Tavilyイテレーションの出力（リストのリスト）
    """
    import re
    from datetime import datetime

    # ==========================================
    # 1. GitHubリポジトリのスコアリング
    # ==========================================
    github_scored = []
    all_repos = []

    # フラット化（Iterationの出力はリストのリスト）
    for batch in github_repos:
        if isinstance(batch, list):
            all_repos.extend(batch)
        elif isinstance(batch, dict) and "repos" in batch:
            all_repos.extend(batch["repos"])

    # 重複排除
    seen_repos = set()
    for repo in all_repos:
        if not isinstance(repo, dict):
            continue
        full_name = repo.get("full_name", "")
        if not full_name or full_name in seen_repos:
            continue
        seen_repos.add(full_name)

        stars = repo.get("stargazers_count", 0)
        forks = repo.get("forks_count", 0)
        has_pages = repo.get("has_pages", False)
        homepage = repo.get("homepage", "")

        # --- スター数ベーススコア ---
        if stars >= 1000:
            star_score = 10
        elif stars >= 500:
            star_score = 8
        elif stars >= 200:
            star_score = 6
        elif stars >= 100:
            star_score = 4
        elif stars >= 50:
            star_score = 2
        else:
            star_score = 1

        # --- 追加シグナルボーナス ---
        bonus = 0
        # docsサイト（homepage or GitHub Pages）があればボーナス
        if homepage and ("docs" in homepage.lower() or "github.io" in homepage.lower()):
            bonus += 2
        if has_pages:
            bonus += 1
        # forks率（コミュニティ関心度）
        if stars > 0 and forks / stars > 0.15:
            bonus += 1

        total_score = star_score + bonus

        github_scored.append({
            "entity": full_name,
            "type": "github_repo",
            "title": repo.get("name", ""),
            "description": repo.get("description", ""),
            "url": repo.get("html_url", ""),
            "stars": stars,
            "score": total_score,
            "signals": ["github_star_surge"],
            "details": f"Stars: {stars}, Forks: {forks}, Homepage: {homepage}"
        })

    # ==========================================
    # 2. Tavilyシグナルのスコアリング
    # ==========================================
    # エンティティ（ドメイン/製品名）ごとにシグナルを集約
    entity_signals = {}

    all_signals = []
    for batch in tavily_signals:
        if isinstance(batch, list):
            all_signals.extend(batch)
        elif isinstance(batch, dict) and "signals" in batch:
            all_signals.extend(batch["signals"])

    for signal in all_signals:
        if not isinstance(signal, dict):
            continue
        url = signal.get("url", "")
        title = signal.get("title", "")
        signal_type = signal.get("signal_type", "unknown")
        weight = signal.get("weight", 1)

        # URLからドメインを抽出してエンティティキーとする
        domain = ""
        domain_match = re.search(r'https?://(?:www\.)?([^/]+)', url)
        if domain_match:
            domain = domain_match.group(1)

        # github.com の場合はリポジトリパスをキーに
        if "github.com" in domain:
            path_match = re.search(r'github\.com/([^/]+/[^/]+)', url)
            if path_match:
                domain = path_match.group(1)

        # producthunt.com の場合はプロダクト名をキーに
        if "producthunt.com" in domain:
            path_match = re.search(r'producthunt\.com/posts/([^/?]+)', url)
            if path_match:
                domain = f"ph:{path_match.group(1)}"

        if not domain:
            domain = title[:50] if title else "unknown"

        if domain not in entity_signals:
            entity_signals[domain] = {
                "entity": domain,
                "type": "web_signal",
                "title": title,
                "url": url,
                "signals": [],
                "signal_types": set(),
                "total_weight": 0,
                "details_list": []
            }

        entity_signals[domain]["signals"].append(signal_type)
        entity_signals[domain]["signal_types"].add(signal_type)
        entity_signals[domain]["total_weight"] += weight
        entity_signals[domain]["details_list"].append(
            f"[{signal_type}] {title[:80]}"
        )

    # --- 複数シグナル同時出現ボーナス ---
    LAUNCH_SIGNAL_COMBO = {"docs_api_reference", "pricing_launch"}
    PRODUCT_SIGNAL_COMBO = {"waitlist_beta", "product_hunt"}
    FULL_LAUNCH_COMBO = {"docs_api_reference", "pricing_launch", "waitlist_beta"}

    tavily_scored = []
    for domain, data in entity_signals.items():
        base_score = data["total_weight"]
        combo_bonus = 0
        combo_labels = []

        types = data["signal_types"]
        # docs + pricing = ローンチ間近
        if types >= LAUNCH_SIGNAL_COMBO:
            combo_bonus += 5
            combo_labels.append("LAUNCH_IMMINENT")
        # waitlist + Product Hunt = 製品公開
        if types >= PRODUCT_SIGNAL_COMBO:
            combo_bonus += 4
            combo_labels.append("PRODUCT_DEBUT")
        # docs + pricing + waitlist = フルローンチ
        if types >= FULL_LAUNCH_COMBO:
            combo_bonus += 8
            combo_labels.append("FULL_LAUNCH")
        # 3種類以上のシグナル同時出現
        if len(types) >= 3:
            combo_bonus += 3
            combo_labels.append("MULTI_SIGNAL")

        total_score = base_score + combo_bonus

        tavily_scored.append({
            "entity": domain,
            "type": data["type"],
            "title": data["title"],
            "url": data["url"],
            "score": total_score,
            "signals": list(types),
            "combo": combo_labels,
            "details": " | ".join(data["details_list"][:5])
        })

    # ==========================================
    # 3. 全シグナル統合・ランキング
    # ==========================================
    all_scored = github_scored + tavily_scored
    all_scored.sort(key=lambda x: x.get("score", 0), reverse=True)

    # 上位30件に絞る
    top_signals = all_scored[:30]

    # テキスト形式レポート生成
    report_lines = []
    report_lines.append(f"## 弱いシグナル検出レポート")
    report_lines.append(f"検出日: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    report_lines.append(f"GitHub検出数: {len(github_scored)}, Web検出数: {len(tavily_scored)}")
    report_lines.append("")

    # スコア別に3段階分類
    critical = [s for s in top_signals if s["score"] >= 15]
    notable = [s for s in top_signals if 8 <= s["score"] < 15]
    watch = [s for s in top_signals if s["score"] < 8]

    if critical:
        report_lines.append("### [CRITICAL] 要注目シグナル (スコア15+)")
        for i, s in enumerate(critical, 1):
            combo_str = f" COMBO:{','.join(s.get('combo', []))}" if s.get('combo') else ""
            report_lines.append(
                f"{i}. [{s['type']}] **{s['entity']}** (スコア:{s['score']}{combo_str})"
            )
            report_lines.append(f"   {s.get('title', '')}")
            report_lines.append(f"   URL: {s.get('url', '')}")
            report_lines.append(f"   シグナル: {', '.join(s.get('signals', []))}")
            report_lines.append(f"   詳細: {s.get('details', '')}")
            report_lines.append("")

    if notable:
        report_lines.append("### [NOTABLE] 注目シグナル (スコア8-14)")
        for i, s in enumerate(notable, 1):
            report_lines.append(
                f"{i}. [{s['type']}] **{s['entity']}** (スコア:{s['score']})"
            )
            report_lines.append(f"   {s.get('title', '')} | {s.get('url', '')}")
            report_lines.append(f"   シグナル: {', '.join(s.get('signals', []))}")
            report_lines.append("")

    if watch:
        report_lines.append("### [WATCH] ウォッチ対象 (スコア8未満)")
        for i, s in enumerate(watch[:10], 1):
            report_lines.append(
                f"{i}. [{s['type']}] {s['entity']} (スコア:{s['score']}) - {', '.join(s.get('signals', []))}"
            )
        report_lines.append("")

    report_text = "\n".join(report_lines)

    return {
        "report": report_text,
        "top_signals": top_signals,
        "critical_count": len(critical),
        "notable_count": len(notable),
        "watch_count": len(watch),
        "total_detected": len(all_scored)
    }
```

---

## 4. LLMノード: シグナル分析プロンプト

```
あなたはAI/テクノロジー業界のインテリジェンスアナリストです。
以下の「弱いシグナル検出レポート」を分析し、開発者・投資家向けのインサイトレポートを作成してください。

## 入力データ
{{#scoring_node.report#}}

## 分析の観点

1. **ローンチ間近の製品**: docs + pricing + waitlist が揃っている製品を特定
2. **急成長OSS**: GitHub stars が急伸しているリポジトリの意味を分析
3. **市場トレンド**: 複数のシグナルから読み取れるマクロトレンド
4. **アクションアイテム**: 開発者として今すぐ確認すべきもの

## 出力フォーマット

### 今週の弱いシグナル サマリー

#### 最重要アラート
（CRITICAL判定されたシグナルの分析。なぜ重要か、何を意味するか）

#### 注目の新製品/OSS
（NOTABLE判定されたものから、特に興味深いものを3-5件ピックアップ）

#### 業界トレンド読み解き
（複数のシグナルを横断的に分析し、大きな動向を2-3点指摘）

#### 今週のアクション
- [ ] 確認すべきAPI/SDK
- [ ] 試すべきOSSツール
- [ ] ウォッチリストに追加すべき企業/プロジェクト

レポートは日本語で、簡潔かつ具体的に記述してください。
```

---

## 5. 環境変数

既存の `AInews_TechIntelligence_v3` に追加が必要な環境変数:

```yaml
environment_variables:
  # 既存
  - name: SUPABASE_URL
    value_type: string
  - name: SUPABASE_ANON_KEY
    value_type: secret
  - name: SLACK_WEBHOOK_URL
    value_type: secret
  # 追加（任意 - 認証ありの場合のみ）
  - name: GITHUB_TOKEN
    value_type: secret
    description: "GitHub Personal Access Token（レートリミット緩和用、なくても動作する）"
```

---

## 6. 既存ワークフローとの統合方針

### 親子アプリ構成での組み込み

```
[親ワークフロー: TechIntelligence_Master]
  |
  +-- [子1: AInews_DeepResearch_Hybrid]     ... 既存ニュース収集
  +-- [子2: GitHub_Trending_Collector]       ... 既存トレンド収集
  +-- [子3: ArXiv_Paper_Collector]           ... 既存論文収集
  +-- [子4: WeakSignal_Detector] <<<NEW>>>   ... 弱いシグナル検出
  |
  +-- [統合LLM] 全ソースを統合したテクノロジーレーダー
  +-- [Slack配信]
```

### WeakSignal_Detectorの内部構成（Difyノード一覧）

| ノードID | ノード名 | 種別 | 説明 |
|----------|---------|------|------|
| ws-001 | Start | start | 開始ノード |
| ws-002 | InitDateQueries | code | 日付計算・クエリ生成 |
| ws-003 | GitHubIteration | iteration | GitHub API呼び出しループ |
| ws-003a | GitHubHTTP | http-request | GitHub Search API呼び出し |
| ws-003b | GitHubParse | code | レスポンスパース |
| ws-004 | TavilyIteration | iteration | Tavily弱いシグナル検索ループ |
| ws-004a | TavilySearch | tool (tavily) | Tavily検索実行 |
| ws-004b | TavilyParse | code | 結果パース |
| ws-005 | ProductHuntSearch | tool (tavily) | PH専用検索 |
| ws-005a | PHParse | code | PH結果パース |
| ws-006 | MergeResults | variable-aggregator | 全結果を集約 |
| ws-007 | ScoreSignals | code | スコアリング（上記Python） |
| ws-008 | AnalyzeLLM | llm | シグナル分析レポート生成 |
| ws-009 | FormatOutput | code | Slack/LINE配信用整形 |
| ws-010 | SlackSend | http-request | Slack Webhook送信 |
| ws-011 | End | end | 終了ノード |

### エッジ（接続）

```
ws-001 -> ws-002
ws-002 -> ws-003 (並列)
ws-002 -> ws-004 (並列)
ws-002 -> ws-005 (並列)
ws-003 内部: ws-003a -> ws-003b
ws-004 内部: ws-004a -> ws-004b
ws-005 -> ws-005a
ws-003 -> ws-006
ws-004 -> ws-006
ws-005a -> ws-006
ws-006 -> ws-007
ws-007 -> ws-008
ws-008 -> ws-009
ws-009 -> ws-010
ws-010 -> ws-011
```

---

## 7. レートリミットと実行コスト

| API | レートリミット | 本ワークフローでの呼び出し数 | 備考 |
|-----|--------------|--------------------------|------|
| GitHub Search API (認証なし) | 10 req/min | 5回 | Iteration並列数=1で対応 |
| GitHub Search API (認証あり) | 30 req/min | 5回 | Token設定で緩和可能 |
| Tavily Search | プランによる | 7回 + 1回(PH) = 8回 | basic searchで十分 |
| LLM (Claude) | - | 1回 | 分析レポート生成 |

**推定実行時間**: 約60-90秒（API応答待ち含む）

---

## 8. 運用上の注意点

1. **日次実行推奨**: cronで毎朝1回実行し、週次でサマリーを生成
2. **ノイズ対策**: スコア閾値を調整し、CRITICALのみ即時通知、それ以外は日次ダイジェストに含める
3. **クエリチューニング**: 検出精度が低い場合、signal_queriesのキーワードを調整する
4. **重複排除**: Supabaseに過去の検出結果を保存し、既出シグナルをフィルタリングする拡張が望ましい
