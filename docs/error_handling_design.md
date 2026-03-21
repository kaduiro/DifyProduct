# AInews_TechIntelligence エラーハンドリング設計書

**作成日:** 2026-03-21
**対象:** AInews_TechIntelligence_v7 ワークフロー
**ステータス:** 設計案

---

## 1. ノード別エラーパターンと対策

### 1-1. HTTPリクエストノード

| ノードID | ノード名 | エラーコード | 原因 | 対策 |
|----------|----------|-------------|------|------|
| 1000000000003 | 前回配信データ取得 | 404 | deliveriesテーブル未作成 or レコード0件 | 空レスポンスとして処理続行。後続ノード（前回データ解析）で空入力を許容する設計にする |
| 1000000000003 | 前回配信データ取得 | 401 | SUPABASE_ANON_KEY無効 | エラー通知Slack送信して即時終了 |
| 1000000000004 | ウォッチリスト取得 | 404 | watch_entitiesテーブル未作成 | デフォルトウォッチリスト（固定カテゴリ5件）で続行 |
| 1000000000005 | ドメイン信頼度取得 | 404 | domain_trustテーブル未作成 | 全ドメインtrust_score=5（中間値）として続行 |
| 1000000000017 | Slack送信（メイン） | 400 | Block Kitペイロード不正 | フォールバック: プレーンテキスト形式で再送信 |
| 1000000000017 | Slack送信（メイン） | 429 | レートリミット | Difyのリトライ設定（max_retries: 3, interval: 100ms）で自動再試行。指数バックオフ推奨 |
| 1000000000017 | Slack送信（メイン） | 500 | Slack側障害 | リトライ3回失敗後、execution_logに記録して終了 |
| 1000000000019 | 配信履歴保存 | 404 | deliveriesテーブル未作成 | エラー通知Slack送信。テーブル自動作成Edge Functionの呼び出しを検討 |
| 1000000000019 | 配信履歴保存 | 409 | 一意制約違反 | 重複配信と判断し、スキップ（正常終了扱い） |
| 1000000000020 | 記事ハッシュ保存 | 404 | article_hashesテーブル未作成 | 同上 |
| 1000000000020 | 記事ハッシュ保存 | 409 | hash一意制約違反 | ON CONFLICT DO NOTHINGをSupabase側で設定。既知の重複として正常終了 |
| 2000000000003 | RSS取得 | タイムアウト | RSSフィード応答なし | 該当フィードをスキップし、他のフィード結果で続行 |
| 2000000000003 | RSS取得 | 403/451 | フィードアクセス拒否 | 該当フィードをスキップ。連続失敗時はRSSソースリストから除外を提案 |
| 2000000000005 | arXiv API取得 | 429 | レートリミット | 3秒間隔のリトライ。arXiv APIは最大3req/s推奨 |
| 2000000000005 | arXiv API取得 | 500/503 | arXiv側障害 | arXiv結果なしで続行（RSS + Tavily結果のみ） |
| (Tavily) | Tavily Search | 429 | APIクォータ超過 | 月次クォータ管理。残クォータ少の場合はクエリ数を削減 |
| (Tavily) | Tavily Search | 500 | Tavily側障害 | RSS/arXiv/GitHub結果のみでレポート生成 |

### 1-2. LLMノード

| ノードID | ノード名 | エラー | 原因 | 対策 |
|----------|----------|--------|------|------|
| 1000000000007 | 検索戦略立案 | トークン上限超過 | 入力データ過大 | 入力を直前のコードノードで3000トークン以下にトリミング |
| 1000000000007 | 検索戦略立案 | API障害（500/503） | Anthropic/OpenAI側障害 | 固定カテゴリクエリ（5件）をフォールバックとして使用 |
| 1000000000010 | クエリ最適化 | レスポンス形式不正 | JSON出力が壊れている | 後続コードノードでJSON.parse失敗時、元のクエリをそのまま使用 |
| 1000000000015 | カテゴリ分類+実務インパクト分析 | トークン上限超過 | 記事数過多 | 入力記事を上位20件に制限するガード |
| 1000000000015 | カテゴリ分類+実務インパクト分析 | API障害 | プロバイダ障害 | 簡易テンプレートベースのレポート生成（後述フォールバック参照） |

### 1-3. コードノード

| ノードID | ノード名 | エラー | 原因 | 対策 |
|----------|----------|--------|------|------|
| 1000000000006 | 前回データ解析 | JSONパースエラー | Supabaseからの空/不正レスポンス | try-exceptで空データとして処理。previous_hashes=[], previous_keywords=[] |
| 1000000000008 | クエリJSON解析 | JSONパースエラー | LLM出力が不正JSON | 正規表現でJSON部分を抽出するフォールバック。失敗時は固定クエリ使用 |
| 1000000000012 | 結果整形+待機 | 型エラー | Tavily結果が想定外の構造 | 各フィールドをget()で安全に取得、デフォルト値を設定 |
| 1000000000014 | 信頼度フィルタ+重複統合+差分検知 | JSONパースエラー | 上流データ不正 | 空リストとして処理。フィルタリングをスキップし全件通過 |
| 2000000000004 | XMLパース | XMLパースエラー | RSSフィードのXML不正 | 該当フィードを空結果として返す。エラーメッセージをログに記録 |
| 2000000000006a | arXiv結果パース | XMLパースエラー | arXiv APIレスポンス不正 | 空結果として返す |
| 1000000000016 | Slack Block Kit生成 | 文字数超過 | レポートが長すぎる | Block Kitの50ブロック制限に合わせてトリミング。要約版を生成 |
| 1000000000018 | 保存データ準備 | JSONパースエラー | 上流データ不正 | 空のdelivery_json, hashes_jsonを返す（保存はスキップ相当） |

### 1-4. イテレーションノード

| ノードID | ノード名 | エラー | 対策 |
|----------|----------|--------|------|
| 1000000000009 | 検索ループ | 個別アイテム失敗 | error_handling_mode: "remove-abnormally"（異常アイテムを除外して続行）を設定。正常に完了したアイテムのみ集約 |
| 2000000000002 | RSS取得ループ | 個別アイテム失敗 | 同上。取得できたフィードの結果のみ集約 |

---

## 2. データ整合性保護の設計

### 2-1. 現状の問題

現在のノード順序:
```
... → Slack Block Kit生成(16) → Slack送信(17) → 保存データ準備(18) → 配信履歴保存(19) / 記事ハッシュ保存(20) → 完了(21)
```

**問題点:**
1. Slack送信(17)成功後にDB保存(19,20)が失敗すると、ユーザーには記事が配信されたがDBには記録されない
2. 次回実行時、article_hashesに記録がないため同じ記事が「新規」として再検出される
3. deliveriesに記録がないため、前回配信データ取得(3)が古いデータを返す

### 2-2. 推奨案: ノード順序の変更（DB保存先行方式）

```
... → Slack Block Kit生成(16) → 保存データ準備(18) → 配信履歴保存(19) / 記事ハッシュ保存(20) → Slack送信(17) → 完了(21)
```

**利点:**
- DB保存が成功した場合のみSlack送信が行われるため、データ整合性が保証される
- DB保存失敗時はSlack送信されないので、「配信されたのに記録がない」状態が発生しない
- 次回実行時の差分検知が確実に機能する

**リスク:**
- DB保存成功 → Slack送信失敗の場合、DBには記録があるがユーザーには届かない
- この場合は「未配信だが記録済み」の状態となり、次回は差分検知で除外される
- 対策: Slack送信失敗時にexecution_logにpartial_failureを記録し、手動再配信の判断材料とする

### 2-3. 代替案: DB保存失敗時のエラー通知

現在のノード順序を維持しつつ、DB保存(19,20)の失敗を検知してエラー通知を送る:

```
... → Slack送信(17) → 保存データ準備(18) → 配信履歴保存(19) / 記事ハッシュ保存(20)
                                                ↓ (失敗時)
                                          エラー通知Slack送信(新規ノード)
```

**利点:**
- 既存のノード順序を変更しない（影響範囲が小さい）
- エラーが発生したことを即座に把握できる

**欠点:**
- データ不整合は発生したまま（手動リカバリが必要）
- 追加ノードの実装コストがかかる

### 2-4. 判定: 推奨案を採用

DB保存先行方式を推奨する。理由:
1. データ整合性が根本的に解決される
2. ノード順序の変更はDify上でエッジの張り替えのみで対応可能
3. Slack送信失敗のリスクはexecution_logで管理可能

---

## 3. フォールバック戦略

### 3-1. データソース障害時のフォールバック

```
優先度1: 全ソース利用可能
  RSS + arXiv + Tavily → LLM分析 → フルレポート

優先度2: Tavily障害
  RSS + arXiv → LLM分析 → 一次情報のみレポート
  ※ Slackメッセージに「Tavily検索が利用不可のため、RSS/arXivの結果のみで構成」と注記

優先度3: RSS全滅
  Tavily → LLM分析 → Tavily結果のみレポート
  ※ 「RSSフィードが取得できなかったため、Tavily検索結果のみで構成」と注記

優先度4: RSS全滅 + Tavily障害
  arXiv → LLM分析 → arXiv論文のみレポート
  ※ 最新の研究動向のみ配信

優先度5: 全ソース障害
  エラー通知のみ送信。レポートは生成しない。
```

### 3-2. LLM障害時のフォールバック

LLMノード（検索戦略立案 or カテゴリ分類+分析）が応答しない場合:

**検索戦略立案(7)の障害:**
- 固定カテゴリ5件のクエリ（初期化・日付計算ノードで生成済み）をそのまま使用
- LLMによるクエリ最適化をスキップ

**カテゴリ分類+実務インパクト分析(15)の障害:**
- 簡易テンプレートベースのレポートを生成:
```
[AI Tech Intelligence - {date_range}]

本日の配信はLLM分析が利用できなかったため、簡易フォーマットで配信します。

■ 収集記事一覧（{count}件）
{各記事のタイトル + URL + ソースドメイン を箇条書き}

※ 詳細な分析・カテゴリ分類は次回配信時に行います。
```

### 3-3. フォールバック判定ロジック（コードノードに実装）

```python
def determine_fallback_level(
    rss_results: list,
    arxiv_results: list,
    tavily_results: list
) -> dict:
    has_rss = len(rss_results) > 0
    has_arxiv = len(arxiv_results) > 0
    has_tavily = len(tavily_results) > 0

    if has_rss and has_tavily:
        level = 1
        note = ""
    elif has_rss and not has_tavily:
        level = 2
        note = "Tavily検索が利用不可のため、RSS/arXivの結果のみで構成しています。"
    elif not has_rss and has_tavily:
        level = 3
        note = "RSSフィードが取得できなかったため、Tavily検索結果のみで構成しています。"
    elif has_arxiv:
        level = 4
        note = "RSS・Tavily共に利用不可のため、arXiv論文のみで構成しています。"
    else:
        level = 5
        note = "全データソースが利用不可のため、レポートを生成できませんでした。"

    return {
        "fallback_level": level,
        "fallback_note": note,
        "should_generate_report": level < 5,
        "total_sources": int(has_rss) + int(has_arxiv) + int(has_tavily)
    }
```

---

## 4. 監視・アラート設計

### 4-1. execution_logテーブルによる実行記録

各ワークフロー実行の開始時にexecution_logレコードをINSERTし、完了時にUPDATEする。

**記録タイミング:**
1. ワークフロー開始直後（status: started）
2. データ収集フェーズ完了後（各ソースの成否を記録）
3. ワークフロー完了時（status: completed / partial_failure / failed）

**ステータス定義:**
| ステータス | 条件 |
|-----------|------|
| started | ワークフロー実行開始 |
| completed | 全ノード正常完了 |
| partial_failure | 一部ソース障害があるがレポート生成・配信は成功 |
| failed | レポート生成または配信に失敗 |

### 4-2. 失敗時のSlack通知

エラーが発生した場合、通常のレポート配信チャンネルとは別に（または同一チャンネルに）エラー通知を送信する。Block Kit形式のペイロードは後述（セクション5参照）。

### 4-3. 連続失敗検知

execution_logの直近3件を参照し、全てfailedの場合にエスカレーション通知を送信する。

**判定クエリ:**
```sql
SELECT COUNT(*) as fail_count
FROM execution_log
WHERE status = 'failed'
ORDER BY execution_date DESC
LIMIT 3;
```

fail_count = 3の場合、エスカレーション通知を送信:
- 通常のエラー通知に加え、「3回連続で失敗しています。手動確認が必要です。」のメッセージを追加
- 可能であれば別チャンネルまたはDMで通知

### 4-4. ヘルスチェック

Supabase Edge Function（`health-check`）を定期実行し、テーブルの存在確認・レコード数確認を行う。詳細は別途Edge Functionコード参照。

---

## 5. エラー通知用Slack Webhookペイロード

### 5-1. 通常エラー通知

```json
{
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "AI Tech Intelligence - 実行エラー",
        "emoji": true
      }
    },
    {
      "type": "section",
      "fields": [
        {
          "type": "mrkdwn",
          "text": "*実行日時:*\n2026-03-21 09:00:00 JST"
        },
        {
          "type": "mrkdwn",
          "text": "*ステータス:*\npartial_failure"
        }
      ]
    },
    {
      "type": "divider"
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*エラー発生ノード:*\n`配信履歴保存` (ノード19)"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*エラーメッセージ:*\n```HTTP 404: relation \"public.deliveries\" does not exist```"
      }
    },
    {
      "type": "section",
      "fields": [
        {
          "type": "mrkdwn",
          "text": "*Slack配信:*\n完了"
        },
        {
          "type": "mrkdwn",
          "text": "*DB保存:*\n失敗"
        }
      ]
    },
    {
      "type": "divider"
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*影響範囲:*\n- Slack配信は正常に完了しましたが、配信履歴がDBに保存されていません\n- 次回実行時に同じ記事が再配信される可能性があります"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*対処方法:*\n1. Supabaseダッシュボードで `deliveries` テーブルの存在を確認\n2. テーブルが存在しない場合: `supabase_schema_v4.sql` を実行\n3. テーブルが存在する場合: RLS(Row Level Security)ポリシーとAPIキーの権限を確認\n4. 手動リカバリ: 該当日の配信データを手動でINSERTする"
      }
    },
    {
      "type": "context",
      "elements": [
        {
          "type": "mrkdwn",
          "text": "workflow_run_id: `abc-123-def-456` | execution_log ID: `xxx-yyy-zzz`"
        }
      ]
    }
  ]
}
```

### 5-2. エスカレーション通知（3回連続失敗）

```json
{
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "AI Tech Intelligence - 3回連続失敗 - 要確認",
        "emoji": true
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*直近3回の実行が全て失敗しています。手動での確認が必要です。*"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*失敗履歴:*\n| 日時 | ステータス | エラー概要 |\n|---|---|---|\n| 2026-03-21 09:00 | failed | Slack送信タイムアウト |\n| 2026-03-19 09:00 | failed | LLM API障害 |\n| 2026-03-17 09:00 | failed | Supabase 401エラー |"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*推奨アクション:*\n1. Supabase Edge Function `health-check` を実行してシステム状態を確認\n2. Difyワークフローの環境変数（APIキー等）が有効か確認\n3. 各外部APIのステータスページを確認\n4. 問題解決後、手動でワークフローをテスト実行"
      }
    },
    {
      "type": "divider"
    },
    {
      "type": "context",
      "elements": [
        {
          "type": "mrkdwn",
          "text": "自動エスカレーション | execution_log の直近3件を参照"
        }
      ]
    }
  ]
}
```

### 5-3. コードノードでのペイロード生成テンプレート

```python
import json
from datetime import datetime

def build_error_payload(
    node_name: str,
    error_message: str,
    slack_delivered: bool,
    db_saved: bool,
    workflow_run_id: str = "",
    remediation_steps: list = None
) -> str:
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S JST")

    if remediation_steps is None:
        remediation_steps = [
            "Supabaseダッシュボードでテーブルの存在を確認",
            "Difyワークフローの環境変数を確認",
            "手動でワークフローをテスト実行"
        ]

    impact_lines = []
    if slack_delivered and not db_saved:
        impact_lines.append("Slack配信は完了しましたが、DB保存に失敗しました")
        impact_lines.append("次回実行時に同じ記事が再配信される可能性があります")
    elif not slack_delivered:
        impact_lines.append("Slack配信が行われていません")
        impact_lines.append("ユーザーにレポートが届いていません")

    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": "AI Tech Intelligence - 実行エラー",
                "emoji": True
            }
        },
        {
            "type": "section",
            "fields": [
                {"type": "mrkdwn", "text": f"*実行日時:*\n{now}"},
                {"type": "mrkdwn", "text": f"*エラーノード:*\n`{node_name}`"}
            ]
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*エラーメッセージ:*\n```{error_message}```"
            }
        },
        {
            "type": "section",
            "fields": [
                {"type": "mrkdwn", "text": f"*Slack配信:*\n{'完了' if slack_delivered else '未実施'}"},
                {"type": "mrkdwn", "text": f"*DB保存:*\n{'完了' if db_saved else '失敗'}"}
            ]
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*影響範囲:*\n" + "\n".join(f"- {line}" for line in impact_lines)
            }
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*対処方法:*\n" + "\n".join(f"{i+1}. {step}" for i, step in enumerate(remediation_steps))
            }
        },
        {
            "type": "context",
            "elements": [
                {"type": "mrkdwn", "text": f"workflow_run_id: `{workflow_run_id}`"}
            ]
        }
    ]

    return json.dumps({"blocks": blocks}, ensure_ascii=False)
```

---

## 6. ノード順序変更の提案

### 6-1. 変更内容

**現状:**
```
Slack Block Kit生成(16) → Slack送信(17) → 保存データ準備(18) → 配信履歴保存(19) → 完了(21)
                                                                → 記事ハッシュ保存(20) → 完了(21)
```

**推奨:**
```
Slack Block Kit生成(16) → 保存データ準備(18) → 配信履歴保存(19) → Slack送信(17) → 完了(21)
                                              → 記事ハッシュ保存(20) ↗
```

### 6-2. 変更の理由

1. **データ整合性の根本解決**: DB保存が成功してからSlack送信することで、「配信済みだがDB未記録」という最も深刻な不整合を防ぐ

2. **冪等性の確保**: article_hashesが先に保存されるため、万が一Slack送信中にワークフローが中断しても、次回実行時に同じ記事が再検出されない

3. **リカバリの容易さ**: DB保存成功・Slack送信失敗の場合は「手動でSlack送信するだけ」で復旧可能。逆の場合（Slack成功・DB失敗）は、どの記事が配信されたかの追跡が困難

4. **ユーザー体験**: ユーザーが同じニュースを2回受け取るのは体験として悪い。DB保存を先にすることで重複配信を確実に防ぐ

### 6-3. リスク分析

| リスク | 発生確率 | 影響度 | 対策 |
|--------|---------|--------|------|
| DB保存成功→Slack送信失敗で未配信 | 低 | 中 | execution_logで検知。手動再送信の仕組みを用意 |
| DB保存の遅延でSlack配信が遅れる | 低 | 低 | Supabaseのレスポンスは通常100ms以下。影響は無視可能 |
| 配信履歴・ハッシュ保存の並列実行で片方だけ失敗 | 低 | 中 | 両方の成功を条件分岐ノードで確認してからSlack送信 |
| Dify上でのエッジ張り替えミス | 中 | 高 | 変更前にYAMLをバックアップ。テスト実行で検証 |

### 6-4. 実装手順

1. `AInews_TechIntelligence_v7.yml` をコピーして `_v8.yml` として作業
2. Dify上でエッジを以下のように変更:
   - 削除: `16→17`, `17→18`
   - 追加: `16→18`（Block Kit生成 → 保存データ準備）
   - 変更: `19→21`, `20→21` を `19→17_check`, `20→17_check` に変更
   - 追加: 条件分岐ノード `17_check`（19と20の両方成功を確認）→ Slack送信(17)
   - 追加: `17→21`（Slack送信 → 完了）
3. テスト実行（各パターン）:
   - 正常系: 全ノード成功
   - DB保存失敗: deliveriesテーブルを一時DROP → Slack送信がスキップされることを確認
   - Slack送信失敗: Webhook URLを無効化 → execution_logにpartial_failureが記録されることを確認

---

## 7. 実装優先度

| 優先度 | 施策 | 工数目安 | 効果 |
|--------|------|---------|------|
| P0（即時） | ノード順序変更（DB保存先行） | 0.5日 | データ整合性の根本解決 |
| P0（即時） | execution_logテーブル作成 | 0.5時間 | 実行履歴の可視化 |
| P1（1週間以内） | コードノードのtry-except強化 | 1日 | 各種パースエラーへの耐性向上 |
| P1（1週間以内） | エラー通知Slackノード追加 | 0.5日 | 障害の即時検知 |
| P2（2週間以内） | フォールバック戦略の実装 | 1.5日 | データソース障害時の可用性 |
| P2（2週間以内） | health-check Edge Function | 0.5日 | 定期的なシステム状態確認 |
| P3（1ヶ月以内） | 連続失敗検知・エスカレーション | 1日 | 長期障害の早期発見 |
