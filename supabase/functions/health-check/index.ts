// =================================================================
// Supabase Edge Function: health-check
// AInews_TechIntelligence ワークフロー用ヘルスチェック
//
// エンドポイント: GET /functions/v1/health-check
// レスポンス: JSON形式のヘルスチェック結果
// =================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

interface TableCheck {
  exists: boolean;
  record_count: number | null;
  estimated_size_kb: number | null;
  extra: Record<string, unknown>;
  error: string | null;
}

interface HealthCheckResult {
  status: "healthy" | "degraded" | "unhealthy";
  checked_at: string;
  tables: {
    domain_trust: TableCheck;
    deliveries: TableCheck;
    watch_entities: TableCheck;
    article_hashes: TableCheck;
    execution_log: TableCheck;
  };
  summary: {
    total_tables: number;
    tables_ok: number;
    tables_missing: number;
    tables_error: number;
  };
  warnings: string[];
}

/**
 * テーブルの存在確認とレコード数取得
 * Supabase REST APIのエラーハンドリングを含む
 */
async function checkTable(
  supabase: ReturnType<typeof createClient>,
  tableName: string,
  extraQuery?: (
    client: ReturnType<typeof createClient>
  ) => Promise<Record<string, unknown>>
): Promise<TableCheck> {
  const result: TableCheck = {
    exists: false,
    record_count: null,
    estimated_size_kb: null,
    extra: {},
    error: null,
  };

  try {
    // レコード数を取得（count のみ、データは取得しない）
    const { count, error } = await supabase
      .from(tableName)
      .select("*", { count: "exact", head: true });

    if (error) {
      // テーブルが存在しない場合のエラーパターン
      if (
        error.message.includes("does not exist") ||
        error.code === "42P01" ||
        error.message.includes("404")
      ) {
        result.exists = false;
        result.error = `テーブル '${tableName}' が存在しません`;
        return result;
      }
      // その他のエラー（権限不足等）
      result.exists = true; // テーブルは存在するがアクセスエラー
      result.error = error.message;
      return result;
    }

    result.exists = true;
    result.record_count = count;

    // 容量概算: 1レコードあたり約0.5KBと仮定（JSONB列が多いため大きめに見積もる）
    if (count !== null) {
      result.estimated_size_kb = Math.round(count * 0.5);
    }

    // 追加クエリ（テーブル固有の情報取得）
    if (extraQuery) {
      try {
        result.extra = await extraQuery(supabase);
      } catch (e) {
        result.extra = {
          error: e instanceof Error ? e.message : "追加クエリ失敗",
        };
      }
    }
  } catch (e) {
    result.error = e instanceof Error ? e.message : "不明なエラー";
  }

  return result;
}

Deno.serve(async (req: Request) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // GETのみ許可
  if (req.method !== "GET") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!supabaseUrl || !supabaseKey) {
      return new Response(
        JSON.stringify({
          error: "環境変数 SUPABASE_URL または SUPABASE_SERVICE_ROLE_KEY が未設定です",
        }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseKey);

    const warnings: string[] = [];

    // --- domain_trust ---
    const domainTrust = await checkTable(supabase, "domain_trust");

    if (domainTrust.exists && domainTrust.record_count === 0) {
      warnings.push(
        "domain_trust テーブルにレコードがありません。信頼度フィルタが機能しません。"
      );
    }

    // --- deliveries ---
    const deliveries = await checkTable(
      supabase,
      "deliveries",
      async (client) => {
        // 最新レコードの配信日を取得
        const { data, error } = await client
          .from("deliveries")
          .select("delivery_date, created_at")
          .order("delivery_date", { ascending: false })
          .limit(1)
          .single();

        if (error || !data) {
          return { latest_delivery: null };
        }

        // 最新配信からの経過日数を計算
        const latestDate = new Date(data.delivery_date);
        const now = new Date();
        const daysSinceLastDelivery = Math.floor(
          (now.getTime() - latestDate.getTime()) / (1000 * 60 * 60 * 24)
        );

        return {
          latest_delivery_date: data.delivery_date,
          latest_created_at: data.created_at,
          days_since_last_delivery: daysSinceLastDelivery,
        };
      }
    );

    if (deliveries.exists && deliveries.extra?.days_since_last_delivery) {
      const days = deliveries.extra.days_since_last_delivery as number;
      if (days > 7) {
        warnings.push(
          `最終配信から${days}日経過しています。ワークフローが停止している可能性があります。`
        );
      } else if (days > 3) {
        warnings.push(
          `最終配信から${days}日経過しています（月水金配信の場合は正常範囲）。`
        );
      }
    }

    // --- watch_entities ---
    const watchEntities = await checkTable(
      supabase,
      "watch_entities",
      async (client) => {
        // watching（active）件数を取得
        const { count: activeCount } = await client
          .from("watch_entities")
          .select("*", { count: "exact", head: true })
          .eq("status", "active");

        const { count: pausedCount } = await client
          .from("watch_entities")
          .select("*", { count: "exact", head: true })
          .eq("status", "paused");

        // entity_type別の内訳
        const { data: typeCounts } = await client.rpc("get_entity_type_counts").select("*");

        // rpcが使えない場合のフォールバック: 各タイプを個別にカウント
        let byType: Record<string, number> = {};
        if (!typeCounts) {
          for (const entityType of ["company", "oss", "category"]) {
            const { count } = await client
              .from("watch_entities")
              .select("*", { count: "exact", head: true })
              .eq("entity_type", entityType)
              .eq("status", "active");
            byType[entityType] = count ?? 0;
          }
        }

        return {
          active_count: activeCount ?? 0,
          paused_count: pausedCount ?? 0,
          by_type: Object.keys(byType).length > 0 ? byType : null,
        };
      }
    );

    if (watchEntities.exists && watchEntities.extra?.active_count === 0) {
      warnings.push(
        "watch_entities にactive状態のエンティティがありません。ウォッチリスト検索が機能しません。"
      );
    }

    // --- article_hashes ---
    const articleHashes = await checkTable(
      supabase,
      "article_hashes",
      async (client) => {
        // 直近7日間のハッシュ数
        const weekAgo = new Date();
        weekAgo.setDate(weekAgo.getDate() - 7);
        const { count: recentCount } = await client
          .from("article_hashes")
          .select("*", { count: "exact", head: true })
          .gte("first_seen_date", weekAgo.toISOString().split("T")[0]);

        return {
          recent_7d_count: recentCount ?? 0,
        };
      }
    );

    // --- execution_log ---
    const executionLog = await checkTable(
      supabase,
      "execution_log",
      async (client) => {
        // 直近の実行結果を取得
        const { data: recentRuns } = await client
          .from("execution_log")
          .select("status, execution_date")
          .order("execution_date", { ascending: false })
          .limit(5);

        // 連続失敗チェック
        let consecutiveFailures = 0;
        if (recentRuns) {
          for (const run of recentRuns) {
            if (run.status === "failed") {
              consecutiveFailures++;
            } else {
              break;
            }
          }
        }

        if (consecutiveFailures >= 3) {
          warnings.push(
            `execution_log: ${consecutiveFailures}回連続で失敗しています。即時確認が必要です。`
          );
        }

        return {
          recent_runs: recentRuns ?? [],
          consecutive_failures: consecutiveFailures,
        };
      }
    );

    // --- サマリ集計 ---
    const allTables = [
      domainTrust,
      deliveries,
      watchEntities,
      articleHashes,
      executionLog,
    ];
    const tablesOk = allTables.filter((t) => t.exists && !t.error).length;
    const tablesMissing = allTables.filter((t) => !t.exists).length;
    const tablesError = allTables.filter((t) => t.exists && t.error).length;

    // ステータス判定
    let overallStatus: "healthy" | "degraded" | "unhealthy";
    if (tablesMissing === 0 && tablesError === 0 && warnings.length === 0) {
      overallStatus = "healthy";
    } else if (tablesMissing >= 3 || tablesError >= 2) {
      overallStatus = "unhealthy";
    } else {
      overallStatus = "degraded";
    }

    const result: HealthCheckResult = {
      status: overallStatus,
      checked_at: new Date().toISOString(),
      tables: {
        domain_trust: domainTrust,
        deliveries: deliveries,
        watch_entities: watchEntities,
        article_hashes: articleHashes,
        execution_log: executionLog,
      },
      summary: {
        total_tables: allTables.length,
        tables_ok: tablesOk,
        tables_missing: tablesMissing,
        tables_error: tablesError,
      },
      warnings: warnings,
    };

    // ステータスコード: healthy=200, degraded=200, unhealthy=503
    const httpStatus = overallStatus === "unhealthy" ? 503 : 200;

    return new Response(JSON.stringify(result, null, 2), {
      status: httpStatus,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    const errorMessage = e instanceof Error ? e.message : "不明なエラー";
    return new Response(
      JSON.stringify({
        status: "unhealthy",
        error: errorMessage,
        checked_at: new Date().toISOString(),
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
