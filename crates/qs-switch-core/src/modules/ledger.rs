//! 签到台账与积分快照：Qoder 服务端既没有签到日志也没有用量统计，
//! 这两类数据全部由本机记录（`~/.qs-switch` 下三份 JSON），并据此聚合出
//! 前端统计页（CreditStatistics 契约）与自动签到调度。
//!
//! 不打印任何凭据：这里只落账号 id / 邮箱 / 数值与结果枚举。

use std::collections::{BTreeMap, HashSet};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde_json::{json, Value};

use crate::modules::auth_codec;
use crate::modules::bundle;
use crate::modules::config::{atomic_write_bytes, PathRoots};
use crate::modules::quota;
use crate::modules::variant::{QoderTarget, QoderVariant};

pub const RETENTION_DAYS: i64 = 30;
const LOGS_CAP: usize = 500;
const SNAPSHOTS_CAP: usize = 5000;
/// 同一账号两条配额快照的最小间隔：账号页会轮询/刷新积分，不节流会把
/// 快照文件写成请求日志。10 分钟足够统计页画日粒度趋势。
const SNAPSHOT_MIN_GAP_SECS: i64 = 600;

static LEDGER_GATE: Mutex<()> = Mutex::new(());

fn checkin_config_path(store: &Path) -> PathBuf {
    store.join("checkin-config.json")
}

fn checkin_logs_path(store: &Path) -> PathBuf {
    store.join("checkin-logs.json")
}

fn snapshots_path(store: &Path) -> PathBuf {
    store.join("credit-snapshots.jsonl")
}

/// 前端 `CheckinConfig` 契约（snake_case 沿用上游）。缺省关闭 —— 自动打网络请求
/// 的开关必须默认关闭。惰性刷新给 6 小时这个可用缺省，不是 0：0 会让设置页刚打开
/// 就显示"每小时无条件刷新"这种从来没发生过的语义。
///
/// 上游还带过 `keepalive_days`（保活天数）与 `start_hour`/`end_hour`，本项目的调度
/// 从未读取过它们。签到是每日一次的幂等领取，「今天签没签」由本机日志即可判定，
/// 不需要第二个时间维度 —— 因此只持久化真正生效的字段，不再留下永不生效的开关。
pub fn read_checkin_config(store: &Path) -> Value {
    let raw: Value = std::fs::read(checkin_config_path(store))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_else(|| json!({}));
    json!({
        "enabled": raw.get("enabled").and_then(|x| x.as_bool()).unwrap_or(false),
        "lazy_refresh_hours": raw.get("lazy_refresh_hours").and_then(|x| x.as_u64()).unwrap_or(6),
    })
}

/// 合并部分字段并落盘。数值按前端输入的 min/max 收口，负数/超界不会写进文件。
pub fn write_checkin_config(store: &Path, patch: &Value) -> crate::Result<Value> {
    let _gate = LEDGER_GATE.lock().unwrap_or_else(|p| p.into_inner());
    let mut cur = read_checkin_config(store);
    if let Some(b) = patch.get("enabled").and_then(|x| x.as_bool()) {
        cur["enabled"] = json!(b);
    }
    if let Some(n) = patch.get("lazy_refresh_hours").and_then(|x| x.as_u64()) {
        cur["lazy_refresh_hours"] = json!(n.clamp(1, 72));
    }
    let text = serde_json::to_vec_pretty(&cur).map_err(|e| e.to_string())?;
    atomic_write_bytes(&checkin_config_path(store), &text)
        .map_err(|e| format!("写签到配置失败: {e}"))?;
    Ok(cur)
}

/// 一条签到日志。`result` 只会是 success / already / error；inactive（官方未开放）
/// 什么都没发生，不记 —— 否则自动签到的每次轮询都会刷出一条噪声。
///
/// 键名走 camelCase 与前端 `CheckinLog` 契约对齐。此前这个结构没有 `rename_all`，
/// 落盘是 `account_id` 而 `src/lib/types.ts` 声明的是 `accountId`：前端读回来恒为
/// undefined，于是 email 为空时连"回落到账号 id"的余地都没有（实测本机三条日志 email
/// 全为 `""`，签到日志整行左侧空白）。`alias` 让已落盘的老 `account_id` 仍能读回，
/// 不需要迁移。
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckinLogEntry {
    pub ts: i64,
    #[serde(default, alias = "account_id")]
    pub account_id: Option<String>,
    #[serde(default)]
    pub email: String,
    /// 展示用的账号名，见 [`account_label`]。历史日志里没有这个键，读回来是空串，
    /// 前端与统计事件都按 `accountName → email → accountId` 回落。
    #[serde(default)]
    pub account_name: String,
    pub result: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default)]
    pub variant: String,
    /// 本次领到的 Credits（claim 响应里 `benefit.amount` 的汇总）。
    /// `already` / `error` 没有这个数，用 `None` 而不是 0 —— 0 会被读成"领到了 0 分"。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claimed: Option<f64>,
    /// 签到前的余额：该账号最近一条配额快照的 `total_remaining`。快照有 10 分钟节流，
    /// 所以这是"上一次记录到的余额"，不是严格意义上的领取瞬间前值。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remaining_before: Option<f64>,
    /// 签到后的余额：领完再查一次配额。查失败时为 `None`，不拿旧值冒充。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remaining_after: Option<f64>,
}

fn read_logs_raw(store: &Path) -> Vec<CheckinLogEntry> {
    std::fs::read(checkin_logs_path(store))
        .ok()
        .and_then(|b| serde_json::from_slice::<Vec<CheckinLogEntry>>(&b).ok())
        .unwrap_or_default()
}

fn write_logs_raw(store: &Path, logs: &[CheckinLogEntry]) -> std::io::Result<()> {
    let text = serde_json::to_vec_pretty(logs)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    atomic_write_bytes(&checkin_logs_path(store), &text)
}

/// 「这条记录是哪个账号」的唯一答案。
///
/// 传进来的 `email` 经常是空的：国内版桌面登录态里 `user.email` 本身就可能没值，
/// 而 `quota::resolve_identity_full` 只回一个 email。账号卡的口径是
/// `nickname || email || uid || id`，统计事件也是同一套，所以这里按
/// `email → 包里的 email → name → uid → account_id` 兜底，别再在第三个地方抄一遍。
pub fn account_label(store: &Path, account_id: &str, email: &str, variant: QoderVariant) -> String {
    let e = email.trim();
    if !e.is_empty() {
        return e.to_string();
    }
    if let Ok(b) = bundle::load(store, account_id, variant, QoderTarget::Desktop) {
        for cand in [
            b.identity.email.as_deref(),
            b.identity.name.as_deref(),
            b.identity.uid.as_deref(),
        ] {
            if let Some(c) = cand.map(str::trim).filter(|s| !s.is_empty()) {
                return c.to_string();
            }
        }
    }
    account_id.to_string()
}

/// 写一条日志时要带的结果数据。
///
/// 用结构体而不是继续往后缀函数上叠位置参数：六个调用点里有五个只关心 result/error，
/// 摊平成 9 个位置参数之后传错顺序是迟早的事，而 `claimed`/余额都是 `Option<f64>`，
/// 编译器一个都抓不出来。
#[derive(Debug, Clone, Default)]
pub struct CheckinOutcome<'a> {
    pub result: &'a str,
    pub error: Option<&'a str>,
    pub claimed: Option<f64>,
    pub remaining_before: Option<f64>,
    pub remaining_after: Option<f64>,
}

impl<'a> CheckinOutcome<'a> {
    pub fn error(msg: &'a str) -> Self {
        Self { result: "error", error: Some(msg), ..Default::default() }
    }

    /// 今日已签（服务端正面回了 CLAIMED）：什么都没领到，所以没有收益数据。
    pub fn already() -> Self {
        Self { result: "already", ..Default::default() }
    }

    pub fn success(claimed: f64, remaining_before: Option<f64>, remaining_after: Option<f64>) -> Self {
        Self {
            result: "success",
            claimed: Some(claimed),
            remaining_before,
            remaining_after,
            ..Default::default()
        }
    }
}

/// 该账号最近一条配额快照的余额；没有快照则 `None`。
///
/// 只读本地 jsonl，不打网络 —— 签到前的余额用它拿，避免为了显示"从多少开始"
/// 而给每个账号多加一次请求。
pub fn latest_credit_remaining(store: &Path, account_id: &str) -> Option<f64> {
    read_snapshots_raw(&snapshots_path(store))
        .into_iter()
        .rev()
        .find(|s| s.account_id == account_id)
        .map(|s| s.total_remaining)
}

/// 非有限的浮点（NaN / inf）不是数据：它会让整条日志的 JSON 序列化失败，
/// 于是那一行**静默消失**。折成 `None`（= 数值未知），前端本来就按未知不显示。
fn finite(v: Option<f64>) -> Option<f64> {
    v.filter(|x| x.is_finite())
}

/// 记录一条签到结果（新的在前；30 天外与超量裁剪）。
pub fn record_checkin_log(
    store: &Path,
    account_id: &str,
    email: &str,
    variant: QoderVariant,
    outcome: CheckinOutcome<'_>,
) {
    // 先算标签再进锁：account_label 要读 bundle.json，而 LEDGER_GATE 是日志与快照
    // 共用的写门，没必要把一次文件读圈在锁里。
    let name = account_label(store, account_id, email, variant);
    let _gate = LEDGER_GATE.lock().unwrap_or_else(|p| p.into_inner());
    let mut logs = read_logs_raw(store);
    logs.insert(
        0,
        CheckinLogEntry {
            ts: chrono::Utc::now().timestamp_millis(),
            account_id: Some(account_id.to_string()),
            email: email.to_string(),
            account_name: name,
            result: outcome.result.to_string(),
            error: outcome.error.map(String::from),
            variant: super::view::variant_key(variant).to_string(),
            claimed: finite(outcome.claimed),
            remaining_before: finite(outcome.remaining_before),
            remaining_after: finite(outcome.remaining_after),
        },
    );
    let cutoff = chrono::Utc::now().timestamp_millis() - RETENTION_DAYS * 86_400_000;
    logs.retain(|l| l.ts >= cutoff);
    logs.truncate(LOGS_CAP);
    let _ = write_logs_raw(store, &logs);
}

/// 日志里的账号现在还在不在库里。
///
/// `local-*` 是"桌面现场账号"的合成 id，本来就没有账号包，不能按"包不存在"判成已删除
/// —— 那会给最常见的一类日志行打上假灰标。
fn account_present(store: &Path, account_id: &str, variant_key: &str) -> bool {
    let variant = super::view::variant_from_key(Some(variant_key));
    if account_id.starts_with("local-") || account_id == super::view::local_account_id(variant) {
        return true;
    }
    bundle::load(store, account_id, variant, QoderTarget::Desktop).is_ok()
}

/// 一条日志对外展示的名字。历史日志没有 `accountName`，按同一口径回落。
fn log_display_name(l: &CheckinLogEntry) -> String {
    if !l.account_name.is_empty() {
        return l.account_name.clone();
    }
    if !l.email.is_empty() {
        return l.email.clone();
    }
    l.account_id.clone().unwrap_or_else(|| "未知账号".into())
}

/// 前端 `get_checkin_logs` 契约：`{ logs: [...] }`。
///
/// 每条再补一个 `accountGone`：账号包在日志写下之后被删掉（"幽灵卡片"那类），
/// 光看日志会找不到对应账号，所以这一位由读取侧现算。按 distinct 账号 id 缓存，
/// 一次读取只 load 几回。
pub fn read_checkin_logs(store: &Path) -> Value {
    let mut present: BTreeMap<String, bool> = BTreeMap::new();
    let logs: Vec<Value> = read_logs_raw(store)
        .iter()
        .map(|l| {
            // 序列化失败也要出一行，而不是让这条日志凭空消失：这一份数据只有本机有，
            // 悄悄丢掉就等于没发生过。
            let mut v = serde_json::to_value(l).unwrap_or_else(|e| {
                json!({ "ts": l.ts, "accountId": l.account_id, "result": l.result,
                        "error": format!("日志序列化失败: {e}") })
            });
            let gone = match l.account_id.as_deref() {
                Some(id) => !*present
                    .entry(id.to_string())
                    .or_insert_with(|| account_present(store, id, &l.variant)),
                None => false,
            };
            v["accountGone"] = json!(gone);
            v
        })
        .collect();
    json!({ "logs": logs })
}

/// 一条配额快照（jsonl 行）。
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct CreditSnapshot {
    pub ts: i64,
    #[serde(default)]
    pub account_id: String,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub variant: String,
    #[serde(default)]
    pub total_capacity: f64,
    #[serde(default)]
    pub total_remaining: f64,
    #[serde(default)]
    pub expiring_soon_remaining: f64,
    #[serde(default)]
    pub soonest_expire_at: Option<i64>,
}

/// 配额获取成功后落一条快照。同一账号 10 分钟内只落一条（按文件内最近一条判）。
pub fn append_credit_snapshot(store: &Path, snap: &CreditSnapshot) {
    let _gate = LEDGER_GATE.lock().unwrap_or_else(|p| p.into_inner());
    let path = snapshots_path(store);
    let last_for_account = read_snapshots_raw(&path)
        .into_iter()
        .rev()
        .find(|s| s.account_id == snap.account_id);
    if let Some(prev) = last_for_account {
        if snap.ts - prev.ts < SNAPSHOT_MIN_GAP_SECS * 1000 {
            return;
        }
    }
    let mut all = read_snapshots_raw(&path);
    all.push(snap.clone());
    let cutoff = chrono::Utc::now().timestamp_millis() - RETENTION_DAYS * 86_400_000;
    all.retain(|s| s.ts >= cutoff);
    if all.len() > SNAPSHOTS_CAP {
        all = all.split_off(all.len() - SNAPSHOTS_CAP);
    }
    let mut buf = Vec::new();
    for s in &all {
        if let Ok(line) = serde_json::to_string(s) {
            buf.extend_from_slice(line.as_bytes());
            buf.push(b'\n');
        }
    }
    let _ = atomic_write_bytes(&path, &buf);
}

fn read_snapshots_raw(path: &Path) -> Vec<CreditSnapshot> {
    let Ok(f) = std::fs::File::open(path) else {
        return Vec::new();
    };
    BufReader::new(f)
        .lines()
        .map_while(|l| l.ok())
        .filter_map(|l| serde_json::from_str(&l).ok())
        .collect()
}

fn read_snapshots(store: &Path) -> Vec<CreditSnapshot> {
    read_snapshots_raw(&snapshots_path(store))
}

/// `-0.0` 会被 `Intl.NumberFormat` 渲染成 `"-0"`：0 就是 0，不该带符号。
/// 配额 API 里出现过 -0 形态（实测 2026-09-21），所以两份宿主输出前统一走一遍。
pub fn normalize_signed_zeros(v: &mut Value) {
    match v {
        Value::Number(n) => {
            if let Some(f) = n.as_f64() {
                if f == 0.0 && f.is_sign_negative() {
                    *v = Value::from(0.0);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(normalize_signed_zeros),
        Value::Object(map) => map.values_mut().for_each(normalize_signed_zeros),
        _ => {}
    }
}

fn date_key_ms(ts: i64) -> String {
    use chrono::TimeZone;
    chrono::Local
        .timestamp_millis_opt(ts)
        .single()
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

fn today_key() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

fn minus_days(today: &str, days: i32) -> String {
    use chrono::NaiveDate;
    NaiveDate::parse_from_str(today, "%Y-%m-%d")
        .ok()
        .and_then(|d| d.checked_sub_signed(chrono::Duration::days(days as i64)))
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| today.to_string())
}

struct UsageTotals {
    today: f64,
    seven_days: f64,
    month: f64,
}

/// 逐账号的日粒度观察消耗：相邻快照的 remaining 下降量按日期归账。
/// 签到领取带来的上升不计为消耗（usage 取 max(0, 下降量)）。
fn account_usage(
    snaps: &[CreditSnapshot],
    account_id: &str,
    today: &str,
    week_start: &str,
    month_prefix: &str,
) -> (UsageTotals, BTreeMap<String, f64>) {
    let mut by_date: BTreeMap<String, f64> = BTreeMap::new();
    let mut mine: Vec<&CreditSnapshot> = snaps
        .iter()
        .filter(|s| s.account_id == account_id)
        .collect();
    mine.sort_by_key(|s| s.ts);
    // 遇到 remaining 上升（签到领取/账号切换/bug修复后跳变）时重置参考基准：
    // 以最后一次上升后的 remaining 为新起点，上升前的历史不再与之做差，
    // 避免「旧高值 → 上升点后新低值」被错误计入消耗。
    let mut ref_remaining = mine.first().map(|s| s.total_remaining).unwrap_or(0.0);
    for snap in mine.iter().skip(1) {
        if snap.total_remaining > ref_remaining {
            // remaining 上升（领取/充值/重置）：更新基准，不计消耗
            ref_remaining = snap.total_remaining;
        } else {
            let drop = ref_remaining - snap.total_remaining;
            if drop > 0.0 {
                let d = date_key_ms(snap.ts);
                *by_date.entry(d).or_insert(0.0) += drop;
            }
            ref_remaining = snap.total_remaining;
        }
    }
    let totals = UsageTotals {
        today: by_date.get(today).copied().unwrap_or(0.0),
        seven_days: by_date
            .iter()
            .filter(|(d, _)| d.as_str() >= week_start && d.as_str() <= today)
            .map(|(_, v)| v)
            .sum(),
        month: by_date
            .iter()
            .filter(|(d, _)| d.starts_with(month_prefix))
            .map(|(_, v)| v)
            .sum(),
    };
    (totals, by_date)
}

/// 前端 `CreditStatistics` 契约。`refresh=true` 时先对全部国内版账号各拉一次真实配额
/// （顺带落快照），再聚合 —— 语义是"统计页的刷新按钮"，不是后台定时任务。
///
/// 已去掉国际版：本函数只统计国内版（`Cn`）。库里若还留着历史国际版账号包（如升级前
/// 导入的 `local-ai`），它不进快照聚合、不进账号明细 —— 界面上"没有国际版"这条要在
/// 数据侧也成立，不能只靠前端筛。
pub fn credit_statistics(roots: &PathRoots, store: &Path, refresh: bool) -> Value {
    if refresh {
        for b in bundle::list_all(store) {
            if b.target == QoderTarget::Desktop && b.variant == QoderVariant::Cn {
                let _ = quota::fetch_credit_expiry_sync(roots, store, &b.account_id, b.variant);
            }
        }
    }

    let snaps: Vec<CreditSnapshot> = read_snapshots(store)
        .into_iter()
        .filter(|s| s.variant == "cn")
        .collect();
    let logs: Vec<CheckinLogEntry> = read_logs_raw(store)
        .into_iter()
        .filter(|l| l.variant == "cn")
        .collect();
    let bundles: Vec<_> = bundle::list_all(store)
        .into_iter()
        .filter(|b| b.variant == QoderVariant::Cn)
        .collect();

    let today = today_key();
    let week_start = minus_days(&today, 6);
    let month_prefix = today.chars().take(7).collect::<String>();

    // 当前登录 uid（只看国内版），用于 isCurrent。
    let current_uids: Vec<String> = auth_codec::read_desktop_auth(roots, QoderVariant::Cn)
        .ok()
        .map(|a| vec![a.user.id.clone()])
        .unwrap_or_default();

    // 账号全集 = 国内版账号包 ∪ 国内版快照里出现过的账号（已过滤掉非国内版）。
    let mut ids: Vec<String> = bundles.iter().map(|b| b.account_id.clone()).collect();
    for s in &snaps {
        if !ids.contains(&s.account_id) {
            ids.push(s.account_id.clone());
        }
    }

    let mut global_daily: BTreeMap<String, f64> = BTreeMap::new();
    let mut accounts = Vec::new();
    let mut summary_current_remaining = 0.0;
    let mut summary_current_capacity = 0.0;
    let mut usage_today = 0.0;
    let mut usage_7 = 0.0;
    let mut usage_month = 0.0;
    let mut today_checked_in_accounts = 0usize;
    let coverage_start: Option<i64> = snaps.iter().map(|s| s.ts).min();

    for id in &ids {
        let b = bundles.iter().find(|b| &b.account_id == id);
        let latest = snaps
            .iter()
            .filter(|s| &s.account_id == id)
            .max_by_key(|s| s.ts);
        let (totals, by_date) = account_usage(&snaps, id, &today, &week_start, &month_prefix);

        let today_log = logs
            .iter()
            .find(|l| l.account_id.as_deref() == Some(id.as_str()) && date_key_ms(l.ts) == today);
        let checked_in_today = today_log.map(|l| l.result == "success" || l.result == "already");
        let last_log = logs.iter().find(|l| l.account_id.as_deref() == Some(id.as_str()));

        if checked_in_today == Some(true) {
            today_checked_in_accounts += 1;
        }

        usage_today += totals.today;
        usage_7 += totals.seven_days;
        usage_month += totals.month;
        for (d, v) in &by_date {
            *global_daily.entry(d.clone()).or_insert(0.0) += v;
        }
        if let Some(s) = latest {
            summary_current_remaining += s.total_remaining;
            summary_current_capacity += s.total_capacity;
        }

        let mut daily_points = Vec::new();
        for (d, usage) in &by_date {
            daily_points.push(json!({ "date": d, "usage": usage }));
        }
        accounts.push(json!({
            "accountId": id,
            "accountName": b.and_then(|b| b.identity.name.clone())
                .or_else(|| latest.and_then(|s| (!s.email.is_empty()).then(|| s.email.clone())))
                .unwrap_or_else(|| id.clone()),
            "isCurrent": b.and_then(|b| b.identity.uid.clone()).map(|u| current_uids.contains(&u)).unwrap_or(false),
            "currentRemaining": latest.map(|s| s.total_remaining),
            "totalCapacity": latest.map(|s| s.total_capacity),
            "lastSnapshotAt": latest.map(|s| s.ts),
            "usageToday": totals.today,
            "usage7Days": totals.seven_days,
            "usageThisMonth": totals.month,
            "checkedInToday": checked_in_today,
            "checkinStatusToday": today_log.map(|l| l.result.clone()),
            "lastCheckinAt": last_log.map(|l| l.ts),
            "lastCheckinResult": last_log.map(|l| l.result.clone()),
            "daily": daily_points,
            "variant": b
                .map(|b| super::view::variant_key(b.variant).to_string())
                .or_else(|| latest.map(|s| s.variant.clone()))
                .unwrap_or_else(|| "cn".to_string()),
        }));
    }

    // 日历连续的 30 天趋势（含 0），图表才不会把缺口画成断线。
    let mut daily = Vec::new();
    if let Some(start) = coverage_start {
        let start_date = date_key_ms(start);
        if let Ok(d0) = chrono::NaiveDate::parse_from_str(&start_date, "%Y-%m-%d") {
            let now = chrono::Local::now().date_naive();
            let mut d = d0;
            while d <= now {
                let key = d.format("%Y-%m-%d").to_string();
                daily.push(json!({
                    "date": key,
                    "usage": global_daily.get(&key).copied().unwrap_or(0.0),
                }));
                d += chrono::Duration::days(1);
            }
        }
        if daily.len() > RETENTION_DAYS as usize {
            let drop = daily.len() - RETENTION_DAYS as usize;
            daily.drain(0..drop);
        }
    }

    let mut today_success = 0usize;
    let mut today_already = 0usize;
    let mut today_failed = 0usize;
    let mut events = Vec::new();
    for l in &logs {
        if date_key_ms(l.ts) == today {
            match l.result.as_str() {
                "success" => today_success += 1,
                "already" => today_already += 1,
                _ => today_failed += 1,
            }
        }
        events.push(json!({
            "kind": "checkin",
            "ts": l.ts,
            "date": date_key_ms(l.ts),
            "accountId": l.account_id,
            "accountName": log_display_name(l),
            "result": l.result,
            "error": l.error,
            "variant": l.variant,
        }));
    }

    let mut out = json!({
        "generatedAt": chrono::Utc::now().timestamp_millis(),
        "retentionDays": RETENTION_DAYS,
        "coverageStartAt": coverage_start,
        "summary": {
            "currentRemaining": summary_current_remaining,
            "currentCapacity": summary_current_capacity,
            "usageToday": usage_today,
            "usage7Days": usage_7,
            "usageThisMonth": usage_month,
            "todayCheckedInAccounts": today_checked_in_accounts,
            "todaySuccess": today_success,
            "todayAlready": today_already,
            "todayFailed": today_failed,
        },
        "daily": daily,
        "accounts": accounts,
        "events": events,
    });
    normalize_signed_zeros(&mut out);
    out
}

/// 今天该账号是否已有某类结果的日志。自动流程用它做两件事：
/// 失败按天去重（否则每小时一轮会把一个坏账号刷成日志墙），以及「当天已签短路」。
pub fn has_today_log(store: &Path, account_id: &str, result: &str) -> bool {
    let today = today_key();
    read_logs_raw(store).iter().any(|l| {
        l.account_id.as_deref() == Some(account_id) && l.result == result && date_key_ms(l.ts) == today
    })
}

/// 今天已成功签到的账号集合（`success` 与 `already` 都算已签）。
/// 自动签到据此短路：本地日志已有今天的结论，就不必再问一次服务端。
fn checked_in_today(store: &Path) -> HashSet<String> {
    let today = today_key();
    read_logs_raw(store)
        .into_iter()
        .filter(|l| {
            date_key_ms(l.ts) == today && (l.result == "success" || l.result == "already")
        })
        .filter_map(|l| l.account_id)
        .collect()
}

/// 自动签到的一次核验：启动时与每 `lazy_refresh_hours` 间隔调用。
/// 只做幂等的"未签则签"，绝不碰切换（换号是另一条红线，由用户亲手决定）。
pub fn run_auto_checkin_once(roots: &PathRoots, store: &Path) -> Value {
    let cfg = read_checkin_config(store);
    if !cfg["enabled"].as_bool().unwrap_or(false) {
        return json!({ "status": "disabled" });
    }
    // 与手动批量签到共用同一道门：抢不到说明手动那一轮正在跑，让出即可。
    let Some(_gate) = quota::try_acquire_checkin() else {
        return json!({ "status": "skipped", "reason": "already_running" });
    };
    // 一轮开始时读一次今天的日志：已签的账号直接跳过网络查询。
    // 签到是每日一次的活动，这条短路能把「每轮 N 次查询」压到「每轮只查未签的」。
    let done_today = checked_in_today(store);
    let mut checked = 0u32;
    let (mut success, mut already, mut inactive, mut error) = (0u32, 0u32, 0u32, 0u32);
    for b in bundle::list_all(store) {
        // 已去掉国际版：自动签到只碰国内版账号包。
        if b.target != QoderTarget::Desktop || b.variant != QoderVariant::Cn {
            continue;
        }
        // 本地已有今天的成功结论 → 短路，省一次 campaigns 查询。
        if done_today.contains(&b.account_id) {
            already += 1;
            continue;
        }
        let st = quota::get_checkin_status_sync(roots, store, &b.account_id, b.variant);
        if st.get("ok").and_then(|x| x.as_bool()) != Some(true) {
            // 失败必须可见：此前只累加计数，而返回值又被调用方 `let _ =` 丢弃，
            // 凭据解不开 / 网络错误这些情况在界面上一个字都看不到。
            // 按天去重 —— 同一账号今天已记过 error 就不再写，否则每小时一轮会刷成日志墙。
            let msg = st
                .get("error")
                .and_then(|e| e.as_str())
                .unwrap_or("查询签到状态失败");
            if !has_today_log(store, &b.account_id, "error") {
                let email = b.identity.email.clone().unwrap_or_default();
                record_checkin_log(store, &b.account_id, &email, b.variant, CheckinOutcome::error(msg));
            }
            error += 1;
            continue;
        }
        if st.get("todayCheckedIn").and_then(|x| x.as_bool()) == Some(true) {
            already += 1;
            continue;
        }
        checked += 1;
        match quota::checkin_sync(roots, store, &b.account_id, b.variant)
            .get("result")
            .and_then(|x| x.as_str())
            .unwrap_or("error")
        {
            "success" => success += 1,
            "already" => already += 1,
            "inactive" => inactive += 1,
            _ => error += 1,
        }
    }
    json!({
        "status": "done",
        "checked": checked,
        "success": success,
        "already": already,
        "inactive": inactive,
        "error": error,
    })
}

/// 两个宿主共用一份自动签到调度：桌面端与 webui 都调用它，行为逐字一致，
/// 避免"同一份 UI、桌面能自动签到、webui 不能"的分叉。
///
/// 只在 `enabled=true` 时动作；每轮开始前重读配置，所以关开关下一轮即生效。
/// 首轮不等惰性刷新：进程一起来就核验一次服务端状态、给未签到的账号补签。
/// 只做签到（幂等的 Credits 领取），绝不碰切换 —— 换号会重启用户正在用的 IDE，
/// 那条红线是"必须用户亲手"。
pub fn spawn_scheduler() {
    std::thread::Builder::new()
        .name("qs-auto-checkin".into())
        .spawn(|| {
            let roots = PathRoots::real();
            loop {
                let store = crate::modules::config::switch_root();
                let cfg = read_checkin_config(&store);
                if cfg["enabled"].as_bool().unwrap_or(false) {
                    let _ = run_auto_checkin_once(&roots, &store);
                    let hours = cfg["lazy_refresh_hours"].as_u64().unwrap_or(6).clamp(1, 72);
                    for _ in 0..hours {
                        // 每小时醒一次复查开关：关掉自动签到后最多 1 小时内退出循环，
                        // 不会拖着一整段惰性刷新间隔还在打服务端。
                        if !read_checkin_config(&store)["enabled"].as_bool().unwrap_or(false) {
                            break;
                        }
                        std::thread::sleep(std::time::Duration::from_secs(3600));
                    }
                } else {
                    std::thread::sleep(std::time::Duration::from_secs(60));
                }
            }
        })
        .ok();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_store() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("qs-ledger-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn checkin_config_roundtrips_and_clamps() {
        let dir = temp_store();
        // 无文件回退默认：enabled 必须是 false（自动打网络的开关不能默认开）。
        let d0 = read_checkin_config(&dir);
        assert_eq!(d0["enabled"], false);
        let merged = write_checkin_config(&dir, &json!({ "enabled": true, "lazy_refresh_hours": 0 })).unwrap();
        assert_eq!(merged["enabled"], true);
        assert_eq!(merged["lazy_refresh_hours"], 1, "低于下限收口到 1");
        // 只写 patch 不能把没提到的字段冲掉。
        let merged = write_checkin_config(&dir, &json!({ "lazy_refresh_hours": 12 })).unwrap();
        assert_eq!(merged["enabled"], true, "未提及的 enabled 必须保留");
        assert_eq!(merged["lazy_refresh_hours"], 12);
        // 上游遗留字段不再持久化：写了也不落盘，界面上不会出现永不生效的开关。
        let merged = write_checkin_config(&dir, &json!({ "keepalive_days": 999 })).unwrap();
        assert!(merged.get("keepalive_days").is_none(), "{merged}");
        std::fs::remove_dir_all(dir).ok();
    }

    /// 测试用的日志条目：新字段一多，逐条写字面量会把 fixture 的意图埋掉。
    fn entry(ts: i64, id: &str, result: &str) -> CheckinLogEntry {
        CheckinLogEntry {
            ts,
            account_id: Some(id.into()),
            email: format!("{id}@x.com"),
            account_name: String::new(),
            result: result.into(),
            error: None,
            variant: "cn".into(),
            claimed: None,
            remaining_before: None,
            remaining_after: None,
        }
    }

    #[test]
    fn checkin_logs_are_recorded_pruned_and_read_back() {
        let dir = temp_store();
        record_checkin_log(
            &dir,
            "acct-a",
            "a@x.com",
            QoderVariant::Cn,
            CheckinOutcome::success(120.0, Some(300.0), Some(420.0)),
        );
        record_checkin_log(&dir, "acct-b", "b@x.com", QoderVariant::Global, CheckinOutcome::error("HTTP 500"));
        let logs = read_checkin_logs(&dir)["logs"].as_array().cloned().unwrap();
        assert_eq!(logs.len(), 2);
        assert_eq!(logs[0]["result"], "error", "新的在前");
        assert_eq!(logs[0]["variant"], "ai");
        assert_eq!(logs[1]["email"], "a@x.com");
        // 键名必须是 camelCase：前端 CheckinLog 按 accountId / accountName 读，
        // 而这个结构此前没有 rename_all，落盘是 account_id —— 前端读回来恒为 undefined。
        assert_eq!(logs[1]["accountId"], "acct-a");
        assert_eq!(logs[1]["accountName"], "a@x.com", "有 email 时展示名就是 email");
        assert_eq!(logs[1]["claimed"], 120.0);
        assert_eq!(logs[1]["remainingBefore"], 300.0);
        assert_eq!(logs[1]["remainingAfter"], 420.0);
        assert_eq!(logs[0]["claimed"], Value::Null, "失败行不带收益数据，也不能是 0");
        // 40 天前的条目在下一次写入时被裁掉。
        std::fs::write(
            checkin_logs_path(&dir),
            serde_json::to_vec(&[
                entry(chrono::Utc::now().timestamp_millis() - 40 * 86_400_000, "acct-old", "success"),
                entry(chrono::Utc::now().timestamp_millis(), "acct-new", "success"),
            ])
            .unwrap(),
        )
        .unwrap();
        record_checkin_log(&dir, "acct-c", "c@x.com", QoderVariant::Cn, CheckinOutcome::already());
        let logs = read_checkin_logs(&dir)["logs"].as_array().cloned().unwrap();
        assert_eq!(logs.len(), 2, "40 天前的条目必须被裁掉: {logs:?}");
        assert!(logs.iter().all(|l| l["accountId"] != "acct-old"), "{logs:?}");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn legacy_snake_case_entries_still_read_and_fall_back_to_account_id() {
        let dir = temp_store();
        // 已落盘的老日志：snake_case 的 account_id，没有 accountName / claimed / 余额字段。
        // 修键名时不能把它们读成"账号未知"，所以 alias 是契约的一部分。
        std::fs::write(
            checkin_logs_path(&dir),
            br#"[{"ts":1790411151842,"account_id":"oauth-01a0bdb8","email":"","result":"success","variant":"cn"}]"#,
        )
        .unwrap();
        let logs = read_checkin_logs(&dir)["logs"].as_array().cloned().unwrap();
        assert_eq!(logs.len(), 1, "旧的 account_id 键必须还能读回来");
        assert_eq!(logs[0]["accountId"], "oauth-01a0bdb8");
        assert_eq!(logs[0]["accountName"], "", "老数据没有展示名，读回来是空串");

        // 展示名由 log_display_name 兜底：email 空 → accountId。
        // 这条正是截图里那行空白（email 恒为空、账号列什么都没有）的修法。
        let l = &read_logs_raw(&dir)[0];
        assert_eq!(log_display_name(l), "oauth-01a0bdb8");
        let stats = credit_statistics(&PathRoots::real(), &dir, false);
        assert_eq!(stats["events"][0]["accountName"], "oauth-01a0bdb8", "{stats}");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn account_label_falls_back_through_bundle_then_id() {
        let dir = temp_store();
        // 没有账号包、email 又是空的（国内版桌面登录态常见）→ 只能回落到账号 id，
        // 但绝不能回落到空串：空串在前端就是一行空白。
        assert_eq!(account_label(&dir, "acct-x", "", QoderVariant::Cn), "acct-x");
        assert_eq!(account_label(&dir, "acct-x", "   ", QoderVariant::Cn), "acct-x", "全空白也算没有");
        assert_eq!(account_label(&dir, "acct-x", "me@x.com", QoderVariant::Cn), "me@x.com");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn read_marks_gone_accounts_but_not_local_ones() {
        let dir = temp_store();
        record_checkin_log(&dir, "acct-deleted", "gone@x.com", QoderVariant::Cn, CheckinOutcome::already());
        record_checkin_log(&dir, "local-cn", "", QoderVariant::Cn, CheckinOutcome::already());
        let logs = read_checkin_logs(&dir)["logs"].as_array().cloned().unwrap();
        // local-cn 是"桌面现场账号"的合成 id，本来就没有账号包，不能判成已删除。
        let by_id = |id: &str| logs.iter().find(|l| l["accountId"] == id).unwrap().clone();
        assert_eq!(by_id("acct-deleted")["accountGone"], true, "库里没有包 = 幽灵账号");
        assert_eq!(by_id("local-cn")["accountGone"], false, "现场账号不能被标成已删除");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn non_finite_credits_do_not_eat_the_log_entry() {
        let dir = temp_store();
        record_checkin_log(
            &dir,
            "acct-nan",
            "nan@x.com",
            QoderVariant::Cn,
            CheckinOutcome::success(f64::NAN, Some(f64::INFINITY), Some(120.0)),
        );
        let logs = read_checkin_logs(&dir)["logs"].as_array().cloned().unwrap();
        assert_eq!(logs.len(), 1, "一条坏数值不能带走整行: {logs:?}");
        assert_eq!(logs[0]["accountId"], "acct-nan");
        assert_eq!(logs[0]["claimed"], Value::Null, "非有限值折成未知");
        assert_eq!(logs[0]["remainingBefore"], Value::Null);
        assert_eq!(logs[0]["remainingAfter"], 120.0);
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn snapshots_are_throttled_and_drive_statistics() {
        let dir = temp_store();
        let now = chrono::Utc::now().timestamp_millis();
        let day = 86_400_000i64;
        let mk = |ts: i64, remaining: f64| CreditSnapshot {
            ts,
            account_id: "acct-a".into(),
            email: "a@x.com".into(),
            variant: "cn".into(),
            total_capacity: 1000.0,
            total_remaining: remaining,
            expiring_soon_remaining: 0.0,
            soonest_expire_at: None,
        };
        // 节流：与上一条（按落盘顺序，即最近时刻）间隔 < 10 分钟的不落。
        append_credit_snapshot(&dir, &mk(now - 5 * day, 900.0));
        append_credit_snapshot(&dir, &mk(now - 5 * day + 60_000, 899.0));
        assert_eq!(read_snapshots(&dir).len(), 1, "60 秒内的重复快照必须被节流");

        append_credit_snapshot(&dir, &mk(now - 2 * day, 850.0));
        append_credit_snapshot(&dir, &mk(now, 750.0));
        let snaps = read_snapshots(&dir);
        assert_eq!(snaps.len(), 3, "{snaps:?}");

        // 观察消耗：900→850=50 归 2 天前，850→750=100 归今天；今天用量 = 100，近 7 天 = 150。
        let stats = credit_statistics(&PathRoots::real(), &dir, false);
        assert_eq!(stats["summary"]["usageToday"], 100.0, "{stats}");
        assert_eq!(stats["summary"]["usage7Days"], 150.0, "{stats}");
        assert_eq!(stats["summary"]["currentRemaining"], 750.0, "{stats}");
        let accs = stats["accounts"].as_array().cloned().unwrap_or_default();
        assert_eq!(accs.len(), 1, "{stats}");
        assert_eq!(accs[0]["accountId"], "acct-a");
        assert_eq!(accs[0]["currentRemaining"], 750.0);
        // 覆盖期从首条快照起，日粒度连续（5 天前 → 今天 = 6 天）。
        assert_eq!(stats["daily"].as_array().map(|d| d.len()), Some(6), "{stats}");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn disabled_config_never_hits_the_network() {
        let dir = temp_store();
        // 无配置文件 = disabled：调度循环必须直接返回，一个账号都不碰。
        let r = run_auto_checkin_once(&PathRoots::real(), &dir);
        assert_eq!(r["status"], "disabled", "{r}");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn today_log_lookup_is_day_and_result_scoped() {
        let dir = temp_store();
        record_checkin_log(&dir, "acct-a", "a@x.com", QoderVariant::Cn, CheckinOutcome::error("HTTP 500"));
        assert!(has_today_log(&dir, "acct-a", "error"));
        assert!(!has_today_log(&dir, "acct-a", "success"), "结果类型必须区分");
        assert!(!has_today_log(&dir, "acct-b", "error"), "账号必须区分");

        // 昨天的 error 不能算今天 —— 否则今天的失败会被永久去重掉，用户再也看不到。
        std::fs::write(
            checkin_logs_path(&dir),
            serde_json::to_vec(&[entry(chrono::Utc::now().timestamp_millis() - 86_400_000, "acct-a", "error")])
                .unwrap(),
        )
        .unwrap();
        assert!(!has_today_log(&dir, "acct-a", "error"), "昨天的日志不算今天");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn checked_in_today_excludes_failures() {
        let dir = temp_store();
        assert!(checked_in_today(&dir).is_empty(), "无日志时短路集合为空");
        record_checkin_log(&dir, "acct-ok", "ok@x.com", QoderVariant::Cn, CheckinOutcome::success(10.0, None, None));
        record_checkin_log(&dir, "acct-already", "al@x.com", QoderVariant::Cn, CheckinOutcome::already());
        record_checkin_log(&dir, "acct-err", "err@x.com", QoderVariant::Cn, CheckinOutcome::error("HTTP 500"));
        let set = checked_in_today(&dir);
        assert!(set.contains("acct-ok"));
        assert!(set.contains("acct-already"));
        // error 绝不能进短路集合：否则查询失败的账号会被当成"已签"永久跳过。
        assert!(!set.contains("acct-err"), "{set:?}");
        std::fs::remove_dir_all(dir).ok();
    }

    /// 互斥门与「启用但库里无账号」串在同一个测试里：两者都碰全局 `CHECKIN_GATE`，
    /// 拆成两个 `#[test]` 会在 cargo 的并行测试下互相抢锁而 flaky。
    #[test]
    fn checkin_gate_serializes_and_enabled_noop_is_done() {
        let first = quota::try_acquire_checkin().expect("首次必须抢到");
        assert!(quota::try_acquire_checkin().is_none(), "持锁期间第二次抢占必须失败");
        drop(first);
        assert!(quota::try_acquire_checkin().is_some(), "释放后必须能再抢到");

        // enabled 但没有账号：一轮跑完、计数全 0，证明门能被正常获取与释放。
        let dir = temp_store();
        write_checkin_config(&dir, &json!({ "enabled": true })).unwrap();
        let r = run_auto_checkin_once(&PathRoots::real(), &dir);
        assert_eq!(r["status"], "done", "{r}");
        assert_eq!(r["checked"], 0);
        assert_eq!(r["error"], 0);
        std::fs::remove_dir_all(dir).ok();
    }
}
