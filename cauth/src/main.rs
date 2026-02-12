use base64::engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine;
use chrono::{DateTime, SecondsFormat, Utc};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command as ProcessCommand;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tempfile::NamedTempFile;
use thiserror::Error;

const CLAUDE_KEYCHAIN_SERVICE_NAME: &str = "Claude Code-credentials";
const CLAUDE_OAUTH_CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const CLAUDE_TOKEN_ENDPOINT: &str = "https://platform.claude.com/v1/oauth/token";
const CLAUDE_USAGE_ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";
const CLAUDE_DEFAULT_SCOPE: &str =
    "user:profile user:inference user:sessions:claude_code user:mcp_servers";
static REFRESH_TRACE_COUNTER: AtomicU64 = AtomicU64::new(0);

type ProcessRunner = Arc<dyn Fn(&str, &[String]) -> ProcessExecutionResult + Send + Sync>;
type RefreshClient = Arc<dyn Fn(&str, &str) -> CliResult<ClaudeRefreshPayload> + Send + Sync>;
type UsageClient = Arc<dyn Fn(&str) -> Option<UsageSummary> + Send + Sync>;
type UsageRawClient = Arc<dyn Fn(&str) -> UsageRawResult + Send + Sync>;

#[derive(Debug, Error)]
#[error("{message}")]
struct CliError {
    message: String,
    exit_code: i32,
}

impl CliError {
    fn new(message: impl Into<String>, exit_code: i32) -> Self {
        Self {
            message: message.into(),
            exit_code,
        }
    }
}

type CliResult<T> = Result<T, CliError>;

#[derive(Debug)]
enum CliCommand {
    Help,
    List,
    Status,
    Save(String),
    Switch(String),
    Refresh,
    CheckUsage {
        account_id: Option<String>,
        json: bool,
    },
}

impl CliCommand {
    fn parse(args: &[String]) -> CliResult<Self> {
        let Some(first) = args.first() else {
            return Ok(Self::List);
        };

        match first.as_str() {
            "-h" | "--help" | "help" => Ok(Self::Help),
            "list" | "ls" => {
                if args.len() != 1 {
                    return Err(CliError::new("usage: cauth list", 2));
                }
                Ok(Self::List)
            }
            "status" => {
                if args.len() != 1 {
                    return Err(CliError::new("usage: cauth status", 2));
                }
                Ok(Self::Status)
            }
            "save" => {
                if args.len() != 2 {
                    return Err(CliError::new("usage: cauth save <profile-name>", 2));
                }
                Ok(Self::Save(args[1].clone()))
            }
            "switch" => {
                if args.len() != 2 {
                    return Err(CliError::new("usage: cauth switch <profile-name>", 2));
                }
                Ok(Self::Switch(args[1].clone()))
            }
            "refresh" => {
                if args.len() != 1 {
                    return Err(CliError::new("usage: cauth refresh", 2));
                }
                Ok(Self::Refresh)
            }
            "check-usage" => {
                let mut account_id = None;
                let mut json = false;
                let mut i = 1;
                while i < args.len() {
                    match args[i].as_str() {
                        "--json" => json = true,
                        "--account" => {
                            i += 1;
                            if i >= args.len() {
                                return Err(CliError::new(
                                    "usage: cauth check-usage [--account <id>] [--json]",
                                    2,
                                ));
                            }
                            account_id = Some(args[i].clone());
                        }
                        _ => {
                            return Err(CliError::new(
                                "usage: cauth check-usage [--account <id>] [--json]",
                                2,
                            ));
                        }
                    }
                    i += 1;
                }
                Ok(Self::CheckUsage { account_id, json })
            }
            _ => Err(CliError::new(format!("unknown command: {}", first), 2)),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum UsageService {
    Claude,
    Codex,
    Gemini,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageAccount {
    id: String,
    service: UsageService,
    label: String,
    root_path: String,
    updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageProfile {
    name: String,
    claude_account_id: Option<String>,
    codex_account_id: Option<String>,
    gemini_account_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct AccountsSnapshot {
    accounts: Vec<UsageAccount>,
    profiles: Vec<UsageProfile>,
}

struct AccountStore {
    root_dir: PathBuf,
}

impl AccountStore {
    fn new(root_dir: PathBuf) -> Self {
        Self { root_dir }
    }

    fn file_path(&self) -> PathBuf {
        self.root_dir.join("accounts.json")
    }

    fn load_snapshot(&self) -> CliResult<AccountsSnapshot> {
        let file_path = self.file_path();
        if !file_path.exists() {
            return Ok(AccountsSnapshot::default());
        }

        let data = fs::read(&file_path).map_err(|err| {
            CliError::new(
                format!("failed to read {}: {}", file_path.display(), err),
                1,
            )
        })?;
        serde_json::from_slice::<AccountsSnapshot>(&data)
            .map_err(|err| CliError::new(format!("failed to parse accounts.json: {}", err), 1))
    }

    fn save_snapshot(&self, snapshot: &AccountsSnapshot) -> CliResult<()> {
        fs::create_dir_all(&self.root_dir).map_err(|err| {
            CliError::new(
                format!(
                    "failed to create account store dir {}: {}",
                    self.root_dir.display(),
                    err
                ),
                1,
            )
        })?;
        let data = serde_json::to_vec_pretty(snapshot)
            .map_err(|err| CliError::new(format!("failed to encode accounts.json: {}", err), 1))?;
        write_file_atomic(&self.file_path(), &data)
    }
}

#[derive(Debug, Clone)]
struct ProcessExecutionResult {
    status: i32,
    stdout: String,
    stderr: String,
}

#[derive(Debug, Clone)]
struct ClaudeCredentials {
    root: Value,
    access_token: Option<String>,
    refresh_token: Option<String>,
    expires_at: Option<DateTime<Utc>>,
    scopes: Vec<String>,
}

#[derive(Debug, Clone)]
struct ClaudeRefreshPayload {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: Option<f64>,
    scope: Option<String>,
}

#[derive(Debug, Clone)]
struct UsageSummary {
    five_hour_percent: Option<i32>,
    five_hour_reset: Option<DateTime<Utc>>,
    seven_day_percent: Option<i32>,
    seven_day_reset: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone)]
struct UsageRawResult {
    request_raw: String,
    response_raw: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CheckUsageInfo {
    name: String,
    available: bool,
    error: bool,
    five_hour_percent: Option<f64>,
    seven_day_percent: Option<f64>,
    five_hour_reset: Option<String>,
    seven_day_reset: Option<String>,
    model: Option<String>,
    plan: Option<String>,
    buckets: Option<Vec<CheckUsageBucket>>,
}

impl CheckUsageInfo {
    fn error_result(name: &str) -> Self {
        Self {
            name: name.to_string(),
            available: true,
            error: true,
            five_hour_percent: None,
            seven_day_percent: None,
            five_hour_reset: None,
            seven_day_reset: None,
            model: None,
            plan: None,
            buckets: None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CheckUsageBucket {
    model_id: String,
    used_percent: Option<f64>,
    reset_at: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CheckUsageOutput {
    claude: CheckUsageInfo,
    codex: Option<CheckUsageInfo>,
    gemini: Option<CheckUsageInfo>,
    zai: Option<CheckUsageInfo>,
    recommendation: Option<String>,
    recommendation_reason: String,
}

#[derive(Debug, Clone)]
struct GeminiCredentials {
    access_token: String,
    refresh_token: Option<String>,
    expiry_date: Option<f64>,
}

#[derive(Debug, Clone)]
struct RefreshResult {
    credentials_data: Vec<u8>,
    email: Option<String>,
    plan: Option<String>,
    key_remaining: String,
    five_hour_percent: Option<i32>,
    five_hour_reset: Option<DateTime<Utc>>,
    seven_day_percent: Option<i32>,
    seven_day_reset: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum RefreshFailureKind {
    NeedsLogin,
    Error,
}

#[derive(Debug, Clone)]
struct RefreshFailure {
    kind: RefreshFailureKind,
    message: String,
}

#[derive(Debug, Clone)]
enum AccountRefreshOutcome {
    Success(RefreshResult),
    Failed(RefreshFailure),
}

#[derive(Debug, Clone)]
struct ClaudeInventoryStatus {
    email: String,
    plan: String,
    key_remaining: String,
    five_hour: String,
    seven_day: String,
    file_state: String,
}

struct CAuthRefreshLogWriter {
    log_dir: PathBuf,
    log_file: PathBuf,
    max_log_bytes: u64,
}

impl CAuthRefreshLogWriter {
    fn new(log_dir: PathBuf) -> Self {
        let log_file = log_dir.join("usage-refresh.log");
        Self {
            log_dir,
            log_file,
            max_log_bytes: 5 * 1024 * 1024,
        }
    }

    fn write(&self, event: &str, fields: &[(&str, Option<String>)]) {
        let _ = self.write_inner(event, fields);
    }

    fn write_inner(&self, event: &str, fields: &[(&str, Option<String>)]) -> std::io::Result<()> {
        fs::create_dir_all(&self.log_dir)?;
        self.rotate_if_needed()?;

        let mut payload = Map::new();
        payload.insert(
            "timestamp".to_string(),
            Value::String(Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)),
        );
        payload.insert("event".to_string(), Value::String(event.to_string()));
        for (key, value) in fields {
            let Some(value) = value else { continue };
            let trimmed = value.trim();
            if trimmed.is_empty() {
                continue;
            }
            payload.insert((*key).to_string(), Value::String(trimmed.to_string()));
        }

        let line = match serde_json::to_string(&Value::Object(payload)) {
            Ok(value) => format!("{}\n", value),
            Err(_) => return Ok(()),
        };
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log_file)?;
        let _ = file.set_permissions(fs::Permissions::from_mode(0o600));
        file.write_all(line.as_bytes())
    }

    fn rotate_if_needed(&self) -> std::io::Result<()> {
        let size = match fs::metadata(&self.log_file) {
            Ok(metadata) => metadata.len(),
            Err(_) => return Ok(()),
        };
        if size <= self.max_log_bytes {
            return Ok(());
        }

        let rotated = self.log_dir.join("usage-refresh.log.1");
        if rotated.exists() {
            let _ = fs::remove_file(&rotated);
        }
        fs::rename(&self.log_file, rotated)
    }
}

struct CAuthApp {
    home_dir: PathBuf,
    agent_root: PathBuf,
    accounts_dir: PathBuf,
    account_store: AccountStore,
    refresh_log_writer: CAuthRefreshLogWriter,
    keychain_service_name: String,
    security_executable: String,
    process_runner: ProcessRunner,
    refresh_client: RefreshClient,
    usage_client: UsageClient,
    usage_raw_client: UsageRawClient,
}

impl CAuthApp {
    fn new(home_dir: PathBuf) -> Self {
        let claude_token_endpoint = std::env::var("CLAUDE_CODE_TOKEN_URL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| CLAUDE_TOKEN_ENDPOINT.to_string());
        let claude_usage_endpoint = std::env::var("CLAUDE_CODE_USAGE_URL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| CLAUDE_USAGE_ENDPOINT.to_string());
        let security_executable = std::env::var("CAUTH_SECURITY_BIN")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "/usr/bin/security".to_string());
        let claude_oauth_client_id = CLAUDE_OAUTH_CLIENT_ID.to_string();

        let refresh_endpoint = claude_token_endpoint.clone();
        let refresh_client_id = claude_oauth_client_id.clone();
        let refresh_client: RefreshClient = Arc::new(move |refresh_token, scope| {
            default_refresh_client(&refresh_endpoint, &refresh_client_id, refresh_token, scope)
        });

        let usage_endpoint = claude_usage_endpoint.clone();
        let usage_client: UsageClient =
            Arc::new(move |access_token| default_usage_client(&usage_endpoint, access_token));
        let usage_raw_endpoint = claude_usage_endpoint.clone();
        let usage_raw_client: UsageRawClient = Arc::new(move |access_token| {
            default_usage_raw_client(&usage_raw_endpoint, access_token)
        });

        Self::with_clients_internal(
            home_dir,
            CLAUDE_KEYCHAIN_SERVICE_NAME.to_string(),
            security_executable,
            Arc::new(default_process_runner),
            refresh_client,
            usage_client,
            usage_raw_client,
        )
    }

    #[cfg(test)]
    fn with_clients(
        home_dir: PathBuf,
        process_runner: ProcessRunner,
        refresh_client: RefreshClient,
        usage_client: UsageClient,
    ) -> Self {
        Self::with_clients_internal(
            home_dir,
            CLAUDE_KEYCHAIN_SERVICE_NAME.to_string(),
            "/usr/bin/security".to_string(),
            process_runner,
            refresh_client,
            usage_client,
            Arc::new(|access_token| default_usage_raw_client(CLAUDE_USAGE_ENDPOINT, access_token)),
        )
    }

    #[cfg(test)]
    fn with_clients_and_usage_raw(
        home_dir: PathBuf,
        process_runner: ProcessRunner,
        refresh_client: RefreshClient,
        usage_client: UsageClient,
        usage_raw_client: UsageRawClient,
    ) -> Self {
        Self::with_clients_internal(
            home_dir,
            CLAUDE_KEYCHAIN_SERVICE_NAME.to_string(),
            "/usr/bin/security".to_string(),
            process_runner,
            refresh_client,
            usage_client,
            usage_raw_client,
        )
    }

    fn with_clients_internal(
        home_dir: PathBuf,
        keychain_service_name: String,
        security_executable: String,
        process_runner: ProcessRunner,
        refresh_client: RefreshClient,
        usage_client: UsageClient,
        usage_raw_client: UsageRawClient,
    ) -> Self {
        let agent_root = home_dir.join(".agent-island");
        let accounts_dir = agent_root.join("accounts");
        let account_store = AccountStore::new(agent_root.clone());
        let refresh_log_writer = CAuthRefreshLogWriter::new(home_dir.join(".agent-island/logs"));

        Self {
            home_dir,
            agent_root,
            accounts_dir,
            account_store,
            refresh_log_writer,
            keychain_service_name,
            security_executable,
            process_runner,
            refresh_client,
            usage_client,
            usage_raw_client,
        }
    }

    fn print_usage(&self) {
        println!(
            "cauth - Claude auth profile CLI\n\n\
             Usage:\n\
               cauth list                     List saved profiles and current account\n\
               cauth status                   Raw usage API request/response for keychain + file\n\
               cauth save <profile-name>      Save current Claude auth into named profile\n\
               cauth switch <profile-name>    Switch active Claude auth to named profile\n\
               cauth refresh                  Refresh all saved Claude profiles and print usage\n\
               cauth check-usage [--json]     Check usage for all providers (Claude/Codex/Gemini/z.ai)\n\
               cauth help                     Show this help"
        );
    }

    fn log_refresh(&self, event: &str, fields: &[(&str, Option<String>)]) {
        self.refresh_log_writer.write(event, fields);
    }

    fn save_current_profile(&self, profile_name: &str) -> CliResult<()> {
        let name = profile_name.trim();
        if name.is_empty() {
            return Err(CliError::new("profile name is required", 1));
        }

        let credential_data = self.load_current_credentials().ok_or_else(|| {
            CliError::new(
                "current Claude credentials not found in ~/.claude/.credentials.json or keychain",
                1,
            )
        })?;

        let mut snapshot = self.account_store.load_snapshot()?;
        let account_id =
            self.resolve_snapshot_account_id_for_credentials(&snapshot, &credential_data);
        let account_root = self.accounts_dir.join(&account_id);
        let account_credential_path = account_root.join(".claude/.credentials.json");
        write_file_atomic(&account_credential_path, &credential_data)?;

        let account = UsageAccount {
            id: account_id.clone(),
            service: UsageService::Claude,
            label: format!("claude:{}", short_hash_hex(&credential_data)),
            root_path: account_root.display().to_string(),
            updated_at: utc_now_iso(),
        };
        upsert_account(&mut snapshot, account);

        let existing = snapshot
            .profiles
            .iter()
            .find(|profile| profile.name == name);
        let profile = UsageProfile {
            name: name.to_string(),
            claude_account_id: Some(account_id.clone()),
            codex_account_id: existing.and_then(|item| item.codex_account_id.clone()),
            gemini_account_id: existing.and_then(|item| item.gemini_account_id.clone()),
        };
        upsert_profile(&mut snapshot, profile);
        self.account_store.save_snapshot(&snapshot)?;

        let parsed = parse_claude_credentials(&credential_data);
        let email = extract_claude_email(&parsed.root).unwrap_or_else(|| "-".to_string());
        let plan = resolve_claude_plan(&parsed.root).unwrap_or_else(|| "-".to_string());
        println!(
            "saved profile {}: {} {} -> {}",
            name, email, plan, account_id
        );
        Ok(())
    }

    fn switch_profile(&self, profile_name: &str) -> CliResult<()> {
        let snapshot = self.account_store.load_snapshot()?;
        let profile = snapshot
            .profiles
            .iter()
            .find(|item| item.name == profile_name)
            .ok_or_else(|| CliError::new(format!("profile not found: {}", profile_name), 1))?;
        let account_id = profile.claude_account_id.clone().ok_or_else(|| {
            CliError::new(
                format!("profile has no Claude account: {}", profile_name),
                1,
            )
        })?;

        let account = snapshot
            .accounts
            .iter()
            .find(|item| item.id == account_id && item.service == UsageService::Claude)
            .ok_or_else(|| {
                CliError::new(
                    format!("Claude account not found for profile: {}", profile_name),
                    1,
                )
            })?;

        let source_path = PathBuf::from(&account.root_path).join(".claude/.credentials.json");
        if !source_path.exists() {
            return Err(CliError::new(
                format!("missing stored credentials: {}", source_path.display()),
                1,
            ));
        }

        let data = fs::read(&source_path).map_err(|err| {
            CliError::new(
                format!(
                    "failed to read stored credentials {}: {}",
                    source_path.display(),
                    err
                ),
                1,
            )
        })?;
        let active_path = self.home_dir.join(".claude/.credentials.json");
        let lock_keys = self.refresh_lock_keys(&data, &account_id, Some(active_path.as_path()));
        let trace_id = next_refresh_trace_id();
        self.with_refresh_lock(&lock_keys, &trace_id, &account_id, || {
            self.sync_active_claude_credentials(&data)
        })?;

        let parsed = parse_claude_credentials(&data);
        let email = extract_claude_email(&parsed.root).unwrap_or_else(|| "-".to_string());
        let plan = resolve_claude_plan(&parsed.root).unwrap_or_else(|| "-".to_string());
        println!("switched profile {}: {} {}", profile_name, email, plan);
        Ok(())
    }

    fn list_profiles(&self) -> CliResult<()> {
        for line in self.profile_inventory_lines()? {
            println!("{}", line);
        }
        Ok(())
    }

    fn status(&self) -> CliResult<()> {
        for line in self.status_report_lines() {
            println!("{}", line);
        }
        Ok(())
    }

    fn status_report_lines(&self) -> Vec<String> {
        let mut lines = Vec::new();

        let keychain_data = self
            .read_keychain(&self.keychain_service_name, None)
            .map(|raw| raw.into_bytes());
        self.append_status_source_lines(
            &mut lines,
            "osxkeychain",
            "service=Claude Code-credentials",
            keychain_data.as_deref(),
            None,
        );

        lines.push(String::new());
        let active_path = self.home_dir.join(".claude/.credentials.json");
        let file_read = fs::read(&active_path);
        let (file_data, file_error) = match file_read {
            Ok(data) => (Some(data), None),
            Err(err) => (
                None,
                Some(format!("failed to read {}: {}", active_path.display(), err)),
            ),
        };
        self.append_status_source_lines(
            &mut lines,
            "~/.claude/.credentials.json",
            &active_path.display().to_string(),
            file_data.as_deref(),
            file_error.as_deref(),
        );

        lines
    }

    fn append_status_source_lines(
        &self,
        lines: &mut Vec<String>,
        source_name: &str,
        source_detail: &str,
        credential_data: Option<&[u8]>,
        read_error: Option<&str>,
    ) {
        lines.push(format!("Source: {}", source_name));
        lines.push(format!("Credential Source Detail: {}", source_detail));

        if let Some(error) = read_error {
            lines.push(format!("Credential Read Error: {}", error));
        }

        let Some(credential_data) = credential_data else {
            lines.push("Raw Credential:".to_string());
            lines.push("  (skipped: credential not found)".to_string());
            lines.push("Raw Request:".to_string());
            lines.push("  (skipped: credential not found)".to_string());
            lines.push("Raw Response:".to_string());
            lines.push("  (skipped: credential not found)".to_string());
            return;
        };

        lines.push("Raw Credential:".to_string());
        lines.push(render_raw_credential(credential_data));

        let parsed = parse_claude_credentials(credential_data);
        let Some(access_token) = parsed.access_token.as_deref() else {
            lines.push("Raw Request:".to_string());
            lines.push("  (skipped: accessToken missing in credential)".to_string());
            lines.push("Raw Response:".to_string());
            lines.push("  (skipped: accessToken missing in credential)".to_string());
            return;
        };

        let raw = (self.usage_raw_client)(access_token);
        lines.push("Raw Request:".to_string());
        lines.push(raw.request_raw);
        lines.push("Raw Response:".to_string());
        lines.push(raw.response_raw);
    }

    fn collect_claude_inventory_status_from_data(
        &self,
        data: &[u8],
        account_id: Option<&str>,
    ) -> ClaudeInventoryStatus {
        let parsed = parse_claude_credentials(data);
        let (email, email_source) = self.resolve_inventory_email(&parsed.root, account_id);
        let plan = resolve_claude_plan(&parsed.root).unwrap_or_else(|| "-".to_string());
        let key_remaining = format_key_remaining(parsed.expires_at.as_ref());
        let usage = self.fetch_claude_usage_summary(parsed.access_token.as_deref());
        self.log_refresh(
            "cauth_email_resolution",
            &[
                ("account_id", account_id.map(|value| value.to_string())),
                ("email", Some(email.clone())),
                ("email_source", Some(email_source)),
            ],
        );
        let five_hour = format_usage_window(
            usage.as_ref().and_then(|item| item.five_hour_percent),
            usage
                .as_ref()
                .and_then(|item| item.five_hour_reset.as_ref()),
        );
        let seven_day = format_usage_window(
            usage.as_ref().and_then(|item| item.seven_day_percent),
            usage
                .as_ref()
                .and_then(|item| item.seven_day_reset.as_ref()),
        );

        ClaudeInventoryStatus {
            email,
            plan,
            key_remaining,
            five_hour,
            seven_day,
            file_state: "ok".to_string(),
        }
    }

    fn collect_claude_inventory_status_from_file(
        &self,
        credential_path: &Path,
        account_id: Option<&str>,
    ) -> ClaudeInventoryStatus {
        if !credential_path.exists() {
            let fallback_email = account_id
                .and_then(email_from_account_id)
                .unwrap_or_else(|| "-".to_string());
            self.log_refresh(
                "cauth_email_resolution",
                &[
                    ("account_id", account_id.map(|value| value.to_string())),
                    ("email", Some(fallback_email.clone())),
                    ("email_source", Some("credential_missing".to_string())),
                ],
            );
            return ClaudeInventoryStatus {
                email: fallback_email,
                plan: "-".to_string(),
                key_remaining: "--".to_string(),
                five_hour: "-- (--)".to_string(),
                seven_day: "-- (--)".to_string(),
                file_state: "missing".to_string(),
            };
        }

        let data = match fs::read(credential_path) {
            Ok(data) => data,
            Err(_) => {
                let fallback_email = account_id
                    .and_then(email_from_account_id)
                    .unwrap_or_else(|| "-".to_string());
                self.log_refresh(
                    "cauth_email_resolution",
                    &[
                        ("account_id", account_id.map(|value| value.to_string())),
                        ("email", Some(fallback_email.clone())),
                        ("email_source", Some("credential_read_error".to_string())),
                    ],
                );
                return ClaudeInventoryStatus {
                    email: fallback_email,
                    plan: "-".to_string(),
                    key_remaining: "--".to_string(),
                    five_hour: "-- (--)".to_string(),
                    seven_day: "-- (--)".to_string(),
                    file_state: "read-error".to_string(),
                };
            }
        };

        self.collect_claude_inventory_status_from_data(&data, account_id)
    }

    fn resolve_inventory_email(&self, root: &Value, account_id: Option<&str>) -> (String, String) {
        if let Some(email) = extract_claude_email(root) {
            return (email, "credential".to_string());
        }
        if let Some(fallback_email) = account_id.and_then(email_from_account_id) {
            return (fallback_email, "account_id_fallback".to_string());
        }
        ("-".to_string(), "missing".to_string())
    }

    fn resolve_snapshot_account_id_for_credentials(
        &self,
        snapshot: &AccountsSnapshot,
        data: &[u8],
    ) -> String {
        let direct_account_id = self.resolve_claude_account_id(data);
        if snapshot.accounts.iter().any(|account| {
            account.service == UsageService::Claude && account.id == direct_account_id
        }) {
            return direct_account_id;
        }

        let Some(active_lock_id) = refresh_lock_id_from_credentials_data(data) else {
            return direct_account_id;
        };

        for account in snapshot
            .accounts
            .iter()
            .filter(|account| account.service == UsageService::Claude)
        {
            let credential_path =
                PathBuf::from(&account.root_path).join(".claude/.credentials.json");
            let Ok(existing_data) = fs::read(&credential_path) else {
                continue;
            };
            if refresh_lock_id_from_credentials_data(&existing_data).as_deref()
                == Some(active_lock_id.as_str())
            {
                return account.id.clone();
            }
        }

        if let Some(account_id) = self.resolve_snapshot_account_id_by_metadata(snapshot, data) {
            return account_id;
        }

        direct_account_id
    }

    fn resolve_snapshot_account_id_by_metadata(
        &self,
        snapshot: &AccountsSnapshot,
        data: &[u8],
    ) -> Option<String> {
        let parsed = parse_claude_credentials(data);
        let target_email = extract_claude_email(&parsed.root);
        let target_team = resolve_claude_is_team(&parsed.root);
        let target_plan = resolve_claude_plan(&parsed.root);
        if target_email.is_none() && target_team.is_none() && target_plan.is_none() {
            return None;
        }

        let mut scored: Vec<(String, i32)> = Vec::new();
        for account in snapshot
            .accounts
            .iter()
            .filter(|account| account.service == UsageService::Claude)
        {
            let credential_path =
                PathBuf::from(&account.root_path).join(".claude/.credentials.json");
            let Ok(existing_data) = fs::read(&credential_path) else {
                continue;
            };

            let existing = parse_claude_credentials(&existing_data);
            let existing_email = extract_claude_email(&existing.root);
            let existing_team = resolve_claude_is_team(&existing.root);
            let existing_plan = resolve_claude_plan(&existing.root);

            let mut score = 0;

            if let Some(target_email) = target_email.as_ref() {
                if existing_email.as_ref() == Some(target_email) {
                    score += 100;
                } else {
                    continue;
                }
            }

            if let Some(target_team) = target_team {
                if let Some(existing_team) = existing_team {
                    if existing_team == target_team {
                        score += 30;
                    } else {
                        continue;
                    }
                }
            }

            if let Some(target_plan) = target_plan.as_ref() {
                if existing_plan.as_ref() == Some(target_plan) {
                    score += 10;
                }
            }

            if score > 0 {
                scored.push((account.id.clone(), score));
            }
        }

        if scored.is_empty() {
            return None;
        }
        scored.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
        if scored.len() > 1 && scored[0].1 == scored[1].1 {
            return None;
        }
        Some(scored[0].0.clone())
    }

    fn profile_inventory_lines(&self) -> CliResult<Vec<String>> {
        let snapshot = self.account_store.load_snapshot()?;
        let mut profiles = snapshot.profiles.clone();
        profiles.sort_by(|left, right| left.name.cmp(&right.name));

        let account_by_id: HashMap<String, UsageAccount> = snapshot
            .accounts
            .iter()
            .cloned()
            .map(|account| (account.id.clone(), account))
            .collect();
        let active_data = self.load_current_credentials();
        let active_account_id = active_data
            .as_ref()
            .map(|data| self.resolve_snapshot_account_id_for_credentials(&snapshot, data));

        let mut claude_status_by_account_id: HashMap<String, ClaudeInventoryStatus> =
            HashMap::new();
        for account in snapshot
            .accounts
            .iter()
            .filter(|account| account.service == UsageService::Claude)
        {
            let credential_path =
                PathBuf::from(&account.root_path).join(".claude/.credentials.json");
            let status = self.collect_claude_inventory_status_from_file(
                &credential_path,
                Some(account.id.as_str()),
            );
            claude_status_by_account_id.insert(account.id.clone(), status);
        }

        let mut lines = Vec::new();
        lines.push("Current Claude:".to_string());
        if let Some(data) = active_data.as_ref() {
            let account_id_text = active_account_id.clone().unwrap_or_else(|| "-".to_string());
            let current_status =
                self.collect_claude_inventory_status_from_data(data, active_account_id.as_deref());

            let linked_profiles = active_account_id
                .as_ref()
                .map(|account_id| {
                    profiles
                        .iter()
                        .filter(|profile| {
                            profile.claude_account_id.as_deref() == Some(account_id.as_str())
                        })
                        .map(|profile| profile.name.clone())
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let linked_profiles_text = if linked_profiles.is_empty() {
                "-".to_string()
            } else {
                linked_profiles.join(",")
            };

            lines.push(format!("  account: {}", account_id_text));
            lines.push(format!("  profiles: {}", linked_profiles_text));
            lines.push(format!("  email: {}", current_status.email));
            lines.push(format!("  plan: {}", current_status.plan));
            lines.push(format!("  5h: {}", current_status.five_hour));
            lines.push(format!("  7d: {}", current_status.seven_day));
            lines.push(format!("  key: {}", current_status.key_remaining));
        } else {
            lines.push("  (none)".to_string());
        }

        lines.push("Profiles:".to_string());
        if profiles.is_empty() {
            lines.push("  (none)".to_string());
        }
        for profile in &profiles {
            let current_marker = if profile.claude_account_id.as_ref() == active_account_id.as_ref()
            {
                " [current]"
            } else {
                ""
            };
            let codex_account_id = profile.codex_account_id.as_deref().unwrap_or("-");
            let gemini_account_id = profile.gemini_account_id.as_deref().unwrap_or("-");

            let Some(account_id) = profile.claude_account_id.as_deref() else {
                lines.push(format!("  {}{}", profile.name, current_marker));
                lines.push("    claude: -".to_string());
                lines.push("    email: -".to_string());
                lines.push("    plan: -".to_string());
                lines.push("    5h: -- (--)".to_string());
                lines.push("    7d: -- (--)".to_string());
                lines.push("    key: --".to_string());
                lines.push(format!("    codex: {}", codex_account_id));
                lines.push(format!("    gemini: {}", gemini_account_id));
                continue;
            };

            let Some(_account) = account_by_id.get(account_id) else {
                lines.push(format!("  {}{}", profile.name, current_marker));
                lines.push(format!("    claude: {}", account_id));
                lines.push("    email: -".to_string());
                lines.push("    plan: -".to_string());
                lines.push("    5h: -- (--)".to_string());
                lines.push("    7d: -- (--)".to_string());
                lines.push("    key: --".to_string());
                lines.push(format!("    codex: {}", codex_account_id));
                lines.push(format!("    gemini: {}", gemini_account_id));
                continue;
            };
            let status = claude_status_by_account_id
                .get(account_id)
                .cloned()
                .unwrap_or_else(|| ClaudeInventoryStatus {
                    email: email_from_account_id(account_id).unwrap_or_else(|| "-".to_string()),
                    plan: "-".to_string(),
                    key_remaining: "--".to_string(),
                    five_hour: "-- (--)".to_string(),
                    seven_day: "-- (--)".to_string(),
                    file_state: "missing".to_string(),
                });

            lines.push(format!("  {}{}", profile.name, current_marker));
            lines.push(format!(
                "    claude: {} ({})",
                account_id, status.file_state
            ));
            lines.push(format!("    email: {}", status.email));
            lines.push(format!("    plan: {}", status.plan));
            lines.push(format!("    5h: {}", status.five_hour));
            lines.push(format!("    7d: {}", status.seven_day));
            lines.push(format!("    key: {}", status.key_remaining));
            lines.push(format!("    codex: {}", codex_account_id));
            lines.push(format!("    gemini: {}", gemini_account_id));
        }

        lines.push("Accounts:".to_string());
        let mut accounts = snapshot.accounts.clone();
        accounts.sort_by(|left, right| left.id.cmp(&right.id));
        if accounts.is_empty() {
            lines.push("  (none)".to_string());
        }

        for account in accounts {
            let linked_profiles = match account.service {
                UsageService::Claude => profiles
                    .iter()
                    .filter(|profile| {
                        profile.claude_account_id.as_deref() == Some(account.id.as_str())
                    })
                    .map(|profile| profile.name.clone())
                    .collect::<Vec<_>>(),
                UsageService::Codex => profiles
                    .iter()
                    .filter(|profile| {
                        profile.codex_account_id.as_deref() == Some(account.id.as_str())
                    })
                    .map(|profile| profile.name.clone())
                    .collect::<Vec<_>>(),
                UsageService::Gemini => profiles
                    .iter()
                    .filter(|profile| {
                        profile.gemini_account_id.as_deref() == Some(account.id.as_str())
                    })
                    .map(|profile| profile.name.clone())
                    .collect::<Vec<_>>(),
            };
            let linked_text = if linked_profiles.is_empty() {
                "-".to_string()
            } else {
                linked_profiles.join(",")
            };

            if account.service == UsageService::Claude {
                let status = claude_status_by_account_id
                    .get(&account.id)
                    .cloned()
                    .unwrap_or_else(|| ClaudeInventoryStatus {
                        email: email_from_account_id(&account.id)
                            .unwrap_or_else(|| "-".to_string()),
                        plan: "-".to_string(),
                        key_remaining: "--".to_string(),
                        five_hour: "-- (--)".to_string(),
                        seven_day: "-- (--)".to_string(),
                        file_state: "missing".to_string(),
                    });
                let current_marker = if active_account_id.as_deref() == Some(account.id.as_str()) {
                    " [current]"
                } else {
                    ""
                };
                lines.push(format!(
                    "  {} [claude]: linked={} file={} email={} plan={} 5h={} 7d={} key={}{}",
                    account.id,
                    linked_text,
                    status.file_state,
                    status.email,
                    status.plan,
                    status.five_hour,
                    status.seven_day,
                    status.key_remaining,
                    current_marker
                ));
                continue;
            }

            let service_name = match account.service {
                UsageService::Codex => "codex",
                UsageService::Gemini => "gemini",
                UsageService::Claude => "claude",
            };
            lines.push(format!(
                "  {} [{}]: linked={}",
                account.id, service_name, linked_text
            ));
        }

        Ok(lines)
    }

    fn refresh_all_profiles(&self) -> CliResult<()> {
        let mut snapshot = self.account_store.load_snapshot()?;
        let mut profiles = snapshot.profiles.clone();
        profiles.sort_by(|left, right| left.name.cmp(&right.name));
        if profiles.is_empty() {
            println!("no profiles");
            return Ok(());
        }

        let account_by_id: HashMap<String, UsageAccount> = snapshot
            .accounts
            .iter()
            .cloned()
            .map(|account| (account.id.clone(), account))
            .collect();
        let active_data = self.load_current_credentials();
        let active_account_id = active_data
            .as_ref()
            .map(|data| self.resolve_snapshot_account_id_for_credentials(&snapshot, data));

        let mut snapshot_changed = false;
        if let (Some(active_data), Some(active_account_id)) =
            (active_data.as_ref(), active_account_id.as_ref())
        {
            if let Some(index) = snapshot.accounts.iter().position(|account| {
                account.service == UsageService::Claude && account.id == *active_account_id
            }) {
                let credential_path = PathBuf::from(&snapshot.accounts[index].root_path)
                    .join(".claude/.credentials.json");
                let needs_write = match fs::read(&credential_path) {
                    Ok(existing_data) => existing_data != *active_data,
                    Err(_) => true,
                };
                if needs_write {
                    write_file_atomic(&credential_path, active_data)?;
                    snapshot.accounts[index].updated_at = utc_now_iso();
                    snapshot_changed = true;
                }
            }
        }
        if snapshot_changed {
            self.account_store.save_snapshot(&snapshot)?;
        }

        let mut refreshed_by_account_id: HashMap<String, AccountRefreshOutcome> = HashMap::new();
        let mut refreshed_by_lock_id: HashMap<String, AccountRefreshOutcome> = HashMap::new();
        let mut touched_account_ids: HashSet<String> = HashSet::new();
        let mut trace_by_account_id: HashMap<String, String> = HashMap::new();

        for profile in &profiles {
            let Some(account_id) = profile.claude_account_id.clone() else {
                continue;
            };
            let Some(account) = account_by_id.get(&account_id) else {
                continue;
            };
            if account.service != UsageService::Claude {
                continue;
            }
            if refreshed_by_account_id.contains_key(&account_id) {
                continue;
            }

            let account_root = PathBuf::from(&account.root_path);
            let credential_path = account_root.join(".claude/.credentials.json");
            if !credential_path.exists() {
                refreshed_by_account_id.insert(
                    account_id.clone(),
                    AccountRefreshOutcome::Failed(RefreshFailure {
                        kind: RefreshFailureKind::Error,
                        message: format!(
                            "missing stored credentials: {}",
                            credential_path.display()
                        ),
                    }),
                );
                continue;
            }

            let current_data = match fs::read(&credential_path) {
                Ok(data) => data,
                Err(err) => {
                    refreshed_by_account_id.insert(
                        account_id.clone(),
                        AccountRefreshOutcome::Failed(RefreshFailure {
                            kind: RefreshFailureKind::Error,
                            message: format!(
                                "failed to read {}: {}",
                                credential_path.display(),
                                err
                            ),
                        }),
                    );
                    continue;
                }
            };
            let trace_id = next_refresh_trace_id();
            trace_by_account_id.insert(account_id.clone(), trace_id.clone());
            let pre_parsed = parse_claude_credentials(&current_data);
            let pre_refresh_fp = token_fingerprint(pre_parsed.refresh_token.as_deref());
            let pre_access_fp = token_fingerprint(pre_parsed.access_token.as_deref());
            let lock_id = self.resolve_refresh_lock_id(&current_data, &account_id);
            let lock_keys =
                self.refresh_lock_keys(&current_data, &account_id, Some(credential_path.as_path()));
            self.log_refresh(
                "cauth_refresh_start",
                &[
                    ("trace_id", Some(trace_id.clone())),
                    ("account_id", Some(account_id.clone())),
                    ("profile", Some(profile.name.clone())),
                    ("lock_id", Some(lock_id.clone())),
                    ("lock_keys", Some(lock_keys.join(","))),
                    ("pre_refresh_fp", pre_refresh_fp.clone()),
                    ("pre_access_fp", pre_access_fp.clone()),
                    (
                        "credential_path",
                        Some(credential_path.display().to_string()),
                    ),
                ],
            );

            if let Some(existing_outcome) = refreshed_by_lock_id.get(&lock_id).cloned() {
                let outcome = match &existing_outcome {
                    AccountRefreshOutcome::Success(existing) => {
                        match self.apply_refreshed_credentials(
                            account_id.as_str(),
                            &credential_path,
                            active_account_id.as_deref(),
                            &existing.credentials_data,
                        ) {
                            Ok(()) => {
                                touched_account_ids.insert(account_id.clone());
                                existing_outcome
                            }
                            Err(err) => {
                                AccountRefreshOutcome::Failed(classify_refresh_failure(&err))
                            }
                        }
                    }
                    AccountRefreshOutcome::Failed(_) => existing_outcome,
                };
                let reused_decision = match &outcome {
                    AccountRefreshOutcome::Success(_) => "reused_success",
                    AccountRefreshOutcome::Failed(failure) => match failure.kind {
                        RefreshFailureKind::NeedsLogin => "reused_needs_login",
                        RefreshFailureKind::Error => "reused_error",
                    },
                };
                self.log_refresh(
                    "cauth_refresh_result",
                    &[
                        ("trace_id", Some(trace_id.clone())),
                        ("account_id", Some(account_id.clone())),
                        ("lock_id", Some(lock_id.clone())),
                        ("decision", Some(reused_decision.to_string())),
                        ("pre_refresh_fp", pre_refresh_fp.clone()),
                        ("pre_access_fp", pre_access_fp.clone()),
                    ],
                );
                refreshed_by_account_id.insert(account_id.clone(), outcome);
                continue;
            }

            let refreshed_data = self.with_refresh_lock(&lock_keys, &trace_id, &account_id, || {
                let latest_data = fs::read(&credential_path).map_err(|err| {
                    CliError::new(
                        format!("failed to re-read {}: {}", credential_path.display(), err),
                        1,
                    )
                })?;
                self.refresh_claude_credentials_always(&latest_data)
            });
            let outcome = match refreshed_data {
                Ok(refreshed_data) => match self.apply_refreshed_credentials(
                    account_id.as_str(),
                    &credential_path,
                    active_account_id.as_deref(),
                    &refreshed_data,
                ) {
                    Ok(()) => {
                        touched_account_ids.insert(account_id.clone());
                        let parsed = parse_claude_credentials(&refreshed_data);
                        let plan = resolve_claude_plan(&parsed.root);
                        let email = extract_claude_email(&parsed.root);
                        let key_remaining = format_key_remaining(parsed.expires_at.as_ref());
                        let usage = self.fetch_claude_usage_summary(parsed.access_token.as_deref());

                        AccountRefreshOutcome::Success(RefreshResult {
                            credentials_data: refreshed_data,
                            email,
                            plan,
                            key_remaining,
                            five_hour_percent: usage
                                .as_ref()
                                .and_then(|item| item.five_hour_percent),
                            five_hour_reset: usage.as_ref().and_then(|item| item.five_hour_reset),
                            seven_day_percent: usage
                                .as_ref()
                                .and_then(|item| item.seven_day_percent),
                            seven_day_reset: usage.as_ref().and_then(|item| item.seven_day_reset),
                        })
                    }
                    Err(err) => AccountRefreshOutcome::Failed(classify_refresh_failure(&err)),
                },
                Err(err) => AccountRefreshOutcome::Failed(classify_refresh_failure(&err)),
            };

            let (decision, post_refresh_fp, post_access_fp, failure_message) = match &outcome {
                AccountRefreshOutcome::Success(result) => {
                    let post = parse_claude_credentials(&result.credentials_data);
                    (
                        "success".to_string(),
                        token_fingerprint(post.refresh_token.as_deref()),
                        token_fingerprint(post.access_token.as_deref()),
                        None,
                    )
                }
                AccountRefreshOutcome::Failed(failure) => {
                    let label = match failure.kind {
                        RefreshFailureKind::NeedsLogin => "needs_login",
                        RefreshFailureKind::Error => "error",
                    };
                    (label.to_string(), None, None, Some(failure.message.clone()))
                }
            };
            self.log_refresh(
                "cauth_refresh_result",
                &[
                    ("trace_id", Some(trace_id)),
                    ("account_id", Some(account_id.clone())),
                    ("lock_id", Some(lock_id.clone())),
                    ("decision", Some(decision)),
                    ("pre_refresh_fp", pre_refresh_fp),
                    ("pre_access_fp", pre_access_fp),
                    ("post_refresh_fp", post_refresh_fp),
                    ("post_access_fp", post_access_fp),
                    ("error", failure_message),
                ],
            );

            refreshed_by_lock_id.insert(lock_id, outcome.clone());
            refreshed_by_account_id.insert(account_id, outcome);
        }

        for account in &mut snapshot.accounts {
            if touched_account_ids.contains(&account.id) {
                account.updated_at = utc_now_iso();
            }
        }
        self.account_store.save_snapshot(&snapshot)?;

        let mut failed_profiles = Vec::new();
        let mut needs_login_profiles = Vec::new();
        for profile in &profiles {
            let Some(account_id) = profile.claude_account_id.as_ref() else {
                println!("{}: - - 5h -- 7d -- (key) --", profile.name);
                continue;
            };
            let Some(outcome) = refreshed_by_account_id.get(account_id) else {
                println!("{}: - - 5h -- 7d -- (key) --", profile.name);
                continue;
            };
            let trace_suffix = trace_by_account_id
                .get(account_id)
                .map(|trace| format!(" [trace:{}]", trace))
                .unwrap_or_default();

            match outcome {
                AccountRefreshOutcome::Success(refreshed) => {
                    let email = refreshed.email.clone().unwrap_or_else(|| "-".to_string());
                    let plan = refreshed.plan.clone().unwrap_or_else(|| "-".to_string());
                    let five = format_usage_window(
                        refreshed.five_hour_percent,
                        refreshed.five_hour_reset.as_ref(),
                    );
                    let seven = format_usage_window(
                        refreshed.seven_day_percent,
                        refreshed.seven_day_reset.as_ref(),
                    );
                    println!(
                        "{}: {} {} 5h {} 7d {} (key) {}{}",
                        profile.name,
                        email,
                        plan,
                        five,
                        seven,
                        refreshed.key_remaining,
                        trace_suffix
                    );
                }
                AccountRefreshOutcome::Failed(failure) => {
                    let label = match failure.kind {
                        RefreshFailureKind::NeedsLogin => "needs-login",
                        RefreshFailureKind::Error => "error",
                    };
                    println!(
                        "{}: - - 5h -- 7d -- (key) -- [{}] {}{}",
                        profile.name,
                        label,
                        truncate_chars(&failure.message, 180),
                        trace_suffix,
                    );
                    failed_profiles.push(profile.name.clone());
                    if failure.kind == RefreshFailureKind::NeedsLogin {
                        needs_login_profiles.push(profile.name.clone());
                    }
                }
            }
        }

        if failed_profiles.is_empty() {
            return Ok(());
        }

        if failed_profiles.len() == needs_login_profiles.len() {
            return Err(CliError::new(
                format!(
                    "{} profile(s) need login: {}",
                    failed_profiles.len(),
                    needs_login_profiles.join(",")
                ),
                1,
            ));
        }

        Err(CliError::new(
            format!(
                "{} profile(s) failed ({} need login): {}",
                failed_profiles.len(),
                needs_login_profiles.len(),
                failed_profiles.join(",")
            ),
            1,
        ))
    }

    fn apply_refreshed_credentials(
        &self,
        account_id: &str,
        credential_path: &Path,
        active_account_id: Option<&str>,
        refreshed_data: &[u8],
    ) -> CliResult<()> {
        write_file_atomic(credential_path, refreshed_data)?;

        if active_account_id == Some(account_id) {
            self.sync_active_claude_credentials(refreshed_data)?;
        }

        Ok(())
    }

    fn load_current_credentials(&self) -> Option<Vec<u8>> {
        let active_path = self.home_dir.join(".claude/.credentials.json");
        let file_data = fs::read(&active_path).ok();
        let keychain_data = self
            .read_keychain(&self.keychain_service_name, None)
            .map(|raw| raw.into_bytes());

        if let Some(keychain_data) = keychain_data {
            return self.merge_current_claude_credentials(&keychain_data, file_data.as_deref());
        }

        file_data
    }

    fn sync_active_claude_credentials(&self, data: &[u8]) -> CliResult<()> {
        let previous_keychain = self.read_keychain(&self.keychain_service_name, None);
        self.save_claude_credentials_to_keychain(data)?;

        let active_path = self.home_dir.join(".claude/.credentials.json");
        if let Err(err) = write_file_atomic(&active_path, data) {
            if let Some(previous_raw) = previous_keychain {
                let _ = self.save_claude_credentials_to_keychain(previous_raw.as_bytes());
            }
            return Err(err);
        }

        Ok(())
    }

    fn merge_current_claude_credentials(
        &self,
        keychain_data: &[u8],
        fallback_file_data: Option<&[u8]>,
    ) -> Option<Vec<u8>> {
        let mut keychain_root = serde_json::from_slice::<Value>(keychain_data).ok()?;
        if !keychain_root.is_object() {
            return Some(keychain_data.to_vec());
        }

        let keychain_refresh = parse_claude_credentials(keychain_data).refresh_token;
        let fallback_root = if let Some(file_data) = fallback_file_data {
            let parsed = serde_json::from_slice::<Value>(file_data).ok();
            if let (Some(parsed_root), Some(keychain_refresh)) =
                (parsed.as_ref(), keychain_refresh.as_ref())
            {
                let parsed_refresh = parse_claude_credentials(file_data).refresh_token;
                if parsed_refresh.as_deref() == Some(keychain_refresh.as_str()) {
                    Some(parsed_root.clone())
                } else {
                    self.load_stored_claude_root_by_refresh(keychain_refresh)
                        .or_else(|| serde_json::from_slice::<Value>(file_data).ok())
                }
            } else {
                parsed
            }
        } else if let Some(keychain_refresh) = keychain_refresh.as_ref() {
            self.load_stored_claude_root_by_refresh(keychain_refresh)
        } else {
            None
        };

        let Some(fallback_root) = fallback_root else {
            return Some(keychain_data.to_vec());
        };
        if !fallback_root.is_object() {
            return Some(keychain_data.to_vec());
        }

        merge_claude_metadata_value(&mut keychain_root, &fallback_root);
        serde_json::to_vec_pretty(&keychain_root).ok()
    }

    fn load_stored_claude_root_by_refresh(&self, refresh_token: &str) -> Option<Value> {
        let account_dirs = fs::read_dir(&self.accounts_dir).ok()?;
        for entry in account_dirs.flatten() {
            let account_path = entry.path();
            let credential_path = account_path.join(".claude/.credentials.json");
            let Ok(data) = fs::read(&credential_path) else {
                continue;
            };
            let parsed = parse_claude_credentials(&data);
            if parsed.refresh_token.as_deref() != Some(refresh_token) {
                continue;
            }
            if let Ok(root) = serde_json::from_slice::<Value>(&data) {
                return Some(root);
            }
        }
        None
    }

    fn resolve_claude_account_id(&self, data: &[u8]) -> String {
        let parsed = parse_claude_credentials(data);
        if let Some(email) = extract_claude_email(&parsed.root) {
            if let Some(slug) = email_slug(&email) {
                if resolve_claude_is_team(&parsed.root) == Some(true) {
                    return format!("acct_claude_team_{}", slug);
                }
                return format!("acct_claude_{}", slug);
            }
        }

        let refresh_token = parsed.refresh_token.unwrap_or_else(|| "-".to_string());
        let stable = format!("claude:refresh:{}", refresh_token);
        format!("acct_claude_{}", short_hash_hex(stable.as_bytes()))
    }

    fn resolve_refresh_lock_id(&self, data: &[u8], fallback: &str) -> String {
        let parsed = parse_claude_credentials(data);
        let Some(refresh_token) = parsed.refresh_token else {
            return fallback.to_string();
        };
        short_hash_hex(refresh_token.as_bytes())
    }

    fn refresh_lock_keys(
        &self,
        data: &[u8],
        account_id: &str,
        credential_path: Option<&Path>,
    ) -> Vec<String> {
        let mut keys = Vec::new();
        if let Some(path) = credential_path {
            keys.push(path.display().to_string());
        } else {
            keys.push(format!("account:{}", account_id));
        }
        if let Some(refresh_fp) = refresh_lock_id_from_credentials_data(data) {
            keys.push(format!("claude-refresh-token:{}", refresh_fp));
        }
        keys.sort();
        keys.dedup();
        keys
    }

    fn with_refresh_lock<T, F>(
        &self,
        lock_ids: &[String],
        trace_id: &str,
        account_id: &str,
        operation: F,
    ) -> CliResult<T>
    where
        F: FnOnce() -> CliResult<T>,
    {
        let lock_root = self.agent_root.join("locks");
        fs::create_dir_all(&lock_root).map_err(|err| {
            CliError::new(
                format!("failed to create lock dir {}: {}", lock_root.display(), err),
                1,
            )
        })?;

        self.log_refresh(
            "refresh_lock_wait",
            &[
                ("trace_id", Some(trace_id.to_string())),
                ("account_id", Some(account_id.to_string())),
                ("lock_keys", Some(lock_ids.join(","))),
            ],
        );

        let mut files = Vec::new();
        for lock_id in lock_ids {
            let lock_path = lock_root.join(process_refresh_lock_file_name(lock_id));
            let file = OpenOptions::new()
                .create(true)
                .read(true)
                .write(true)
                .truncate(false)
                .open(&lock_path)
                .map_err(|err| {
                    CliError::new(
                        format!("failed to open lock file {}: {}", lock_path.display(), err),
                        1,
                    )
                })?;
            let _ = file.set_permissions(fs::Permissions::from_mode(0o600));
            file.lock_exclusive().map_err(|err| {
                CliError::new(
                    format!("failed to acquire lock {}: {}", lock_path.display(), err),
                    1,
                )
            })?;
            files.push(file);
        }

        self.log_refresh(
            "refresh_lock_acquired",
            &[
                ("trace_id", Some(trace_id.to_string())),
                ("account_id", Some(account_id.to_string())),
                ("lock_keys", Some(lock_ids.join(","))),
            ],
        );

        let result = operation();
        let result_label = if result.is_ok() { "success" } else { "error" };
        for file in files.into_iter().rev() {
            let _ = file.unlock();
        }
        self.log_refresh(
            "refresh_lock_released",
            &[
                ("trace_id", Some(trace_id.to_string())),
                ("account_id", Some(account_id.to_string())),
                ("result", Some(result_label.to_string())),
            ],
        );
        result
    }

    fn refresh_claude_credentials_always(&self, data: &[u8]) -> CliResult<Vec<u8>> {
        let parsed = parse_claude_credentials(data);
        let refresh_token = parsed
            .refresh_token
            .as_deref()
            .ok_or_else(|| CliError::new("missing refresh token in stored credentials", 1))?;

        let scope = if parsed.scopes.is_empty() {
            CLAUDE_DEFAULT_SCOPE.to_string()
        } else {
            parsed.scopes.join(" ")
        };
        let payload = (self.refresh_client)(refresh_token, &scope)?;
        let next_refresh_token = payload
            .refresh_token
            .clone()
            .unwrap_or_else(|| refresh_token.to_string());

        let mut root = parsed.root.clone();
        let oauth_object = ensure_oauth_object(&mut root)?;
        oauth_object.insert(
            "accessToken".to_string(),
            Value::String(payload.access_token.clone()),
        );
        oauth_object.insert(
            "refreshToken".to_string(),
            Value::String(next_refresh_token),
        );

        if let Some(expires_in) = payload.expires_in {
            let expires_at_ms =
                Utc::now().timestamp_millis() + (expires_in * 1000.0).round() as i64;
            oauth_object.insert("expiresAt".to_string(), Value::Number(expires_at_ms.into()));
        }
        if let Some(scope_string) = payload.scope {
            let scopes = normalize_scope_string(&scope_string);
            let scope_values = scopes.into_iter().map(Value::String).collect::<Vec<_>>();
            oauth_object.insert("scopes".to_string(), Value::Array(scope_values));
        }

        serde_json::to_vec_pretty(&root).map_err(|err| {
            CliError::new(
                format!("failed to encode refreshed credentials: {}", err),
                1,
            )
        })
    }

    fn fetch_claude_usage_summary(&self, access_token: Option<&str>) -> Option<UsageSummary> {
        let token = access_token?;
        (self.usage_client)(token)
    }

    fn read_keychain(&self, service: &str, account: Option<&str>) -> Option<String> {
        let mut args = vec![
            "find-generic-password".to_string(),
            "-s".to_string(),
            service.to_string(),
        ];
        if let Some(account_name) = account {
            args.push("-a".to_string());
            args.push(account_name.to_string());
        }
        args.push("-w".to_string());

        let result = (self.process_runner)(&self.security_executable, &args);
        if result.status != 0 {
            return None;
        }
        let trimmed = result.stdout.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    }

    fn save_claude_credentials_to_keychain(&self, data: &[u8]) -> CliResult<()> {
        let raw = std::str::from_utf8(data)
            .map_err(|_| CliError::new("credentials are not valid UTF-8 JSON", 1))?;

        let account_name = self
            .resolve_claude_keychain_account_name()
            .or_else(|| std::env::var("USER").ok())
            .unwrap_or_else(|| "default".to_string());

        let args = vec![
            "add-generic-password".to_string(),
            "-a".to_string(),
            account_name,
            "-s".to_string(),
            self.keychain_service_name.clone(),
            "-w".to_string(),
            raw.to_string(),
            "-U".to_string(),
        ];
        let result = (self.process_runner)(&self.security_executable, &args);
        if result.status != 0 {
            return Err(CliError::new(
                format!("failed to update keychain: {}", result.stderr.trim()),
                1,
            ));
        }
        Ok(())
    }

    fn resolve_claude_keychain_account_name(&self) -> Option<String> {
        let args = vec![
            "find-generic-password".to_string(),
            "-s".to_string(),
            self.keychain_service_name.clone(),
            "-g".to_string(),
        ];
        let result = (self.process_runner)(&self.security_executable, &args);
        if result.status != 0 {
            return None;
        }

        let text = result.stderr;
        let needle = "\"acct\"<blob>=\"";
        let start = text.find(needle)?;
        let after = &text[start + needle.len()..];
        let end = after.find('"')?;
        let account = after[..end].trim().to_string();
        if account.is_empty() {
            None
        } else {
            Some(account)
        }
    }

    fn check_usage(&self, account_id: Option<&str>, json: bool) -> CliResult<()> {
        let claude = self.fetch_claude_check_usage(account_id);
        let codex = self.fetch_codex_check_usage();
        let gemini = self.fetch_gemini_check_usage();
        let zai = self.fetch_zai_check_usage();

        let recommendation = compute_check_usage_recommendation(
            &claude,
            codex.as_ref(),
            gemini.as_ref(),
            zai.as_ref(),
        );

        let output = CheckUsageOutput {
            claude,
            codex,
            gemini,
            zai,
            recommendation: recommendation.0,
            recommendation_reason: recommendation.1,
        };

        if json {
            let json_string = serde_json::to_string_pretty(&output).map_err(|err| {
                CliError::new(
                    format!("failed to serialize check-usage output: {}", err),
                    1,
                )
            })?;
            println!("{}", json_string);
        } else {
            self.print_check_usage_text(&output);
        }
        Ok(())
    }

    fn print_check_usage_text(&self, output: &CheckUsageOutput) {
        self.print_check_usage_provider_text(&output.claude);
        if let Some(ref codex) = output.codex {
            self.print_check_usage_provider_text(codex);
        }
        if let Some(ref gemini) = output.gemini {
            self.print_check_usage_provider_text(gemini);
        }
        if let Some(ref zai) = output.zai {
            self.print_check_usage_provider_text(zai);
        }
        if let Some(ref name) = output.recommendation {
            println!(
                "recommendation: {} ({})",
                name, output.recommendation_reason
            );
        } else {
            println!("recommendation: {}", output.recommendation_reason);
        }
    }

    fn print_check_usage_provider_text(&self, info: &CheckUsageInfo) {
        if !info.available {
            println!("{}: not installed", info.name);
            return;
        }
        if info.error {
            println!("{}: error", info.name);
            return;
        }
        let five = info
            .five_hour_percent
            .map(|v| format!("{}%", v as i32))
            .unwrap_or_else(|| "--".to_string());
        let seven = info
            .seven_day_percent
            .map(|v| format!("{}%", v as i32))
            .unwrap_or_else(|| "--".to_string());
        let plan = info.plan.as_deref().unwrap_or("-");
        let model = info.model.as_deref().unwrap_or("-");
        println!(
            "{}: 5h {} 7d {} plan={} model={}",
            info.name, five, seven, plan, model
        );
    }

    fn fetch_claude_check_usage(&self, account_id: Option<&str>) -> CheckUsageInfo {
        let (data, account_credential_path, should_sync_active) =
            if let Some(account_id) = account_id {
                let snapshot = match self.account_store.load_snapshot() {
                    Ok(s) => s,
                    Err(_) => return CheckUsageInfo::error_result("Claude"),
                };
                let account = match snapshot
                    .accounts
                    .iter()
                    .find(|a| a.id == account_id && a.service == UsageService::Claude)
                {
                    Some(a) => a,
                    None => return CheckUsageInfo::error_result("Claude"),
                };
                let path = PathBuf::from(&account.root_path).join(".claude/.credentials.json");
                let data = match fs::read(&path) {
                    Ok(d) => d,
                    Err(_) => return CheckUsageInfo::error_result("Claude"),
                };
                (data, Some(path), false)
            } else {
                let data = match self.load_current_credentials() {
                    Some(d) => d,
                    None => return CheckUsageInfo::error_result("Claude"),
                };
                (data, None, true)
            };

        let working_data = match self.refresh_claude_credentials_always(&data) {
            Ok(refreshed) => {
                if should_sync_active {
                    let _ = self.sync_active_claude_credentials(&refreshed);
                } else if let Some(path) = account_credential_path.as_ref() {
                    let _ = write_file_atomic(path, &refreshed);
                }
                refreshed
            }
            Err(_) => data,
        };

        let parsed = parse_claude_credentials(&working_data);
        let plan = resolve_claude_plan(&parsed.root);
        let usage = self.fetch_claude_usage_summary(parsed.access_token.as_deref());

        CheckUsageInfo {
            name: "Claude".to_string(),
            available: true,
            error: usage.is_none(),
            five_hour_percent: usage
                .as_ref()
                .and_then(|u| u.five_hour_percent)
                .map(|v| v as f64),
            seven_day_percent: usage
                .as_ref()
                .and_then(|u| u.seven_day_percent)
                .map(|v| v as f64),
            five_hour_reset: usage
                .as_ref()
                .and_then(|u| u.five_hour_reset.as_ref())
                .map(|d| d.to_rfc3339_opts(SecondsFormat::Millis, true)),
            seven_day_reset: usage
                .as_ref()
                .and_then(|u| u.seven_day_reset.as_ref())
                .map(|d| d.to_rfc3339_opts(SecondsFormat::Millis, true)),
            model: None,
            plan,
            buckets: None,
        }
    }

    fn fetch_codex_check_usage(&self) -> Option<CheckUsageInfo> {
        let auth_path = self.home_dir.join(".codex/auth.json");
        if !auth_path.exists() {
            return None;
        }

        let auth_data = match fs::read(&auth_path) {
            Ok(d) => d,
            Err(_) => return Some(CheckUsageInfo::error_result("Codex")),
        };
        let auth_root: Value = match serde_json::from_slice(&auth_data) {
            Ok(v) => v,
            Err(_) => return Some(CheckUsageInfo::error_result("Codex")),
        };

        let access_token = get_path_string(&auth_root, &["tokens", "access_token"]);
        let account_id = get_path_string(&auth_root, &["tokens", "account_id"]);
        let (access_token, account_id) = match (access_token, account_id) {
            (Some(at), Some(ai)) => (at, ai),
            _ => return Some(CheckUsageInfo::error_result("Codex")),
        };

        let client = match reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
        {
            Ok(c) => c,
            Err(_) => return Some(CheckUsageInfo::error_result("Codex")),
        };

        let response = match client
            .get("https://chatgpt.com/backend-api/wham/usage")
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .header("User-Agent", "cauth/0.1")
            .bearer_auth(&access_token)
            .header("ChatGPT-Account-Id", &account_id)
            .send()
        {
            Ok(r) => r,
            Err(_) => return Some(CheckUsageInfo::error_result("Codex")),
        };

        if !response.status().is_success() {
            return Some(CheckUsageInfo::error_result("Codex"));
        }

        let root: Value = match response.json() {
            Ok(v) => v,
            Err(_) => return Some(CheckUsageInfo::error_result("Codex")),
        };

        if root.get("rate_limit").is_none() || root.get("plan_type").is_none() {
            return Some(CheckUsageInfo::error_result("Codex"));
        }

        let plan_type = value_as_string(root.get("plan_type"));
        let rate_limit = root.get("rate_limit");
        let primary = rate_limit.and_then(|rl| rl.get("primary_window"));
        let secondary = rate_limit.and_then(|rl| rl.get("secondary_window"));

        let five_hour_percent = primary
            .and_then(|w| w.get("used_percent"))
            .and_then(value_as_f64)
            .map(|v| v.round());
        let five_hour_reset = primary
            .and_then(|w| w.get("reset_at"))
            .and_then(value_as_f64)
            .and_then(|ts| DateTime::<Utc>::from_timestamp(ts as i64, 0))
            .map(|d| d.to_rfc3339_opts(SecondsFormat::Millis, true));
        let seven_day_percent = secondary
            .and_then(|w| w.get("used_percent"))
            .and_then(value_as_f64)
            .map(|v| v.round());
        let seven_day_reset = secondary
            .and_then(|w| w.get("reset_at"))
            .and_then(value_as_f64)
            .and_then(|ts| DateTime::<Utc>::from_timestamp(ts as i64, 0))
            .map(|d| d.to_rfc3339_opts(SecondsFormat::Millis, true));

        let model = self.read_codex_model();

        Some(CheckUsageInfo {
            name: "Codex".to_string(),
            available: true,
            error: false,
            five_hour_percent,
            seven_day_percent,
            five_hour_reset,
            seven_day_reset,
            model,
            plan: plan_type,
            buckets: None,
        })
    }

    fn read_codex_model(&self) -> Option<String> {
        let config_path = self.home_dir.join(".codex/config.toml");
        let raw = fs::read_to_string(&config_path).ok()?;
        for line in raw.lines() {
            let trimmed = line.trim();
            let after_model = trimmed.strip_prefix("model")?;
            let after_eq = after_model.trim().strip_prefix('=')?;
            let value = after_eq.trim();
            if let Some(quoted) = value.strip_prefix('"') {
                return quoted.split('"').next().map(|s| s.to_string());
            }
            if let Some(quoted) = value.strip_prefix('\'') {
                return quoted.split('\'').next().map(|s| s.to_string());
            }
        }
        None
    }

    fn fetch_gemini_check_usage(&self) -> Option<CheckUsageInfo> {
        if !self.is_gemini_installed() {
            return None;
        }

        let credentials = match self.get_gemini_credentials() {
            Some(c) => c,
            None => return Some(CheckUsageInfo::error_result("Gemini")),
        };

        let valid_credentials = if self.gemini_token_needs_refresh(&credentials) {
            match self.refresh_gemini_token(&credentials) {
                Some(c) => c,
                None => return Some(CheckUsageInfo::error_result("Gemini")),
            }
        } else {
            credentials
        };

        let project_id = match self.get_gemini_project_id(&valid_credentials) {
            Some(id) => id,
            None => return Some(CheckUsageInfo::error_result("Gemini")),
        };

        let client = match reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
        {
            Ok(c) => c,
            Err(_) => return Some(CheckUsageInfo::error_result("Gemini")),
        };

        let response = match client
            .post("https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .header("User-Agent", "cauth/0.1")
            .bearer_auth(&valid_credentials.access_token)
            .json(&serde_json::json!({ "project": project_id }))
            .send()
        {
            Ok(r) => r,
            Err(_) => return Some(CheckUsageInfo::error_result("Gemini")),
        };

        if !response.status().is_success() {
            return Some(CheckUsageInfo::error_result("Gemini"));
        }

        let root: Value = match response.json() {
            Ok(v) => v,
            Err(_) => return Some(CheckUsageInfo::error_result("Gemini")),
        };

        let model = self.read_gemini_model();
        let raw_buckets = root.get("buckets").and_then(Value::as_array);

        let mut buckets = Vec::new();
        let mut primary_used_percent: Option<f64> = None;
        let mut primary_reset_at: Option<String> = None;
        let mut model_used_percent: Option<f64> = None;
        let mut model_reset_at: Option<String> = None;

        if let Some(raw_buckets) = raw_buckets {
            for bucket in raw_buckets {
                let model_id =
                    value_as_string(bucket.get("modelId")).unwrap_or_else(|| "unknown".to_string());
                let remaining_fraction = bucket.get("remainingFraction").and_then(value_as_f64);
                let used_percent = remaining_fraction.map(|r| ((1.0 - r) * 100.0).round());
                let reset_time =
                    value_as_string(bucket.get("resetTime")).and_then(|s| normalize_to_iso(&s));

                if model
                    .as_deref()
                    .map(|m| model_id.contains(m))
                    .unwrap_or(false)
                {
                    model_used_percent = used_percent;
                    model_reset_at = reset_time.clone();
                }

                if primary_used_percent.is_none() {
                    primary_used_percent = used_percent;
                    primary_reset_at = reset_time.clone();
                }

                buckets.push(CheckUsageBucket {
                    model_id,
                    used_percent,
                    reset_at: reset_time,
                });
            }
        }

        let active_used_percent = model_used_percent.or(primary_used_percent);
        let active_reset_at = if model_used_percent.is_some() {
            model_reset_at
        } else {
            primary_reset_at
        };

        Some(CheckUsageInfo {
            name: "Gemini".to_string(),
            available: true,
            error: false,
            five_hour_percent: active_used_percent,
            seven_day_percent: None,
            five_hour_reset: active_reset_at,
            seven_day_reset: None,
            model,
            plan: None,
            buckets: if buckets.is_empty() {
                None
            } else {
                Some(buckets)
            },
        })
    }

    fn is_gemini_installed(&self) -> bool {
        if self.get_gemini_token_from_keychain().is_some() {
            return true;
        }
        self.home_dir.join(".gemini/oauth_creds.json").exists()
    }

    fn get_gemini_token_from_keychain(&self) -> Option<GeminiCredentials> {
        let raw = self.read_keychain("gemini-cli-oauth", Some("main-account"))?;
        let root: Value = serde_json::from_str(&raw).ok()?;
        let access_token = get_path_string(&root, &["token", "accessToken"])?;
        let refresh_token = get_path_string(&root, &["token", "refreshToken"]);
        let expiry_date = get_path_value(&root, &["token", "expiresAt"]).and_then(value_as_f64);
        Some(GeminiCredentials {
            access_token,
            refresh_token,
            expiry_date,
        })
    }

    fn get_gemini_credentials(&self) -> Option<GeminiCredentials> {
        if let Some(creds) = self.get_gemini_token_from_keychain() {
            return Some(creds);
        }
        let oauth_path = self.home_dir.join(".gemini/oauth_creds.json");
        let raw = fs::read_to_string(&oauth_path).ok()?;
        let root: Value = serde_json::from_str(&raw).ok()?;
        let access_token = value_as_string(root.get("access_token"))?;
        let refresh_token = value_as_string(root.get("refresh_token"));
        let expiry_date = root.get("expiry_date").and_then(value_as_f64);
        Some(GeminiCredentials {
            access_token,
            refresh_token,
            expiry_date,
        })
    }

    fn gemini_token_needs_refresh(&self, credentials: &GeminiCredentials) -> bool {
        let Some(expiry) = credentials.expiry_date else {
            return false;
        };
        let buffer_ms = 5.0 * 60.0 * 1000.0;
        expiry < (Utc::now().timestamp_millis() as f64) + buffer_ms
    }

    fn refresh_gemini_token(&self, credentials: &GeminiCredentials) -> Option<GeminiCredentials> {
        let refresh_token = credentials.refresh_token.as_deref()?;
        let client_id = std::env::var("GEMINI_OAUTH_CLIENT_ID").ok()?;
        let client_secret = std::env::var("GEMINI_OAUTH_CLIENT_SECRET").ok()?;
        if client_id.is_empty() || client_secret.is_empty() {
            return None;
        }

        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .ok()?;

        let response = client
            .post("https://oauth2.googleapis.com/token")
            .form(&[
                ("grant_type", "refresh_token"),
                ("refresh_token", refresh_token),
                ("client_id", client_id.as_str()),
                ("client_secret", client_secret.as_str()),
            ])
            .send()
            .ok()?;

        if !response.status().is_success() {
            return None;
        }

        let root: Value = response.json().ok()?;
        let access_token = value_as_string(root.get("access_token"))?;
        let new_refresh =
            value_as_string(root.get("refresh_token")).unwrap_or_else(|| refresh_token.to_string());
        let expires_in = root.get("expires_in").and_then(value_as_f64);
        let expiry_date = expires_in.map(|e| Utc::now().timestamp_millis() as f64 + e * 1000.0);

        Some(GeminiCredentials {
            access_token,
            refresh_token: Some(new_refresh),
            expiry_date,
        })
    }

    fn get_gemini_project_id(&self, credentials: &GeminiCredentials) -> Option<String> {
        if let Ok(project_id) = std::env::var("GOOGLE_CLOUD_PROJECT") {
            if !project_id.is_empty() {
                return Some(project_id);
            }
        }
        if let Ok(project_id) = std::env::var("GOOGLE_CLOUD_PROJECT_ID") {
            if !project_id.is_empty() {
                return Some(project_id);
            }
        }

        let settings = self.read_gemini_settings();
        if let Some(project) = settings
            .as_ref()
            .and_then(|s| s.get("cloudaicompanionProject"))
            .and_then(|v| value_as_string(Some(v)))
        {
            return Some(project);
        }
        if let Some(project) = settings
            .as_ref()
            .and_then(|s| s.get("project"))
            .and_then(|v| value_as_string(Some(v)))
        {
            return Some(project);
        }

        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .ok()?;

        let response = client
            .post("https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .bearer_auth(&credentials.access_token)
            .json(&serde_json::json!({
                "metadata": {
                    "ideType": "GEMINI_CLI",
                    "platform": "PLATFORM_UNSPECIFIED",
                    "pluginType": "GEMINI"
                }
            }))
            .send()
            .ok()?;

        if !response.status().is_success() {
            return None;
        }

        let root: Value = response.json().ok()?;
        value_as_string(root.get("cloudaicompanionProject"))
    }

    fn read_gemini_settings(&self) -> Option<Value> {
        let settings_path = self.home_dir.join(".gemini/settings.json");
        let raw = fs::read_to_string(&settings_path).ok()?;
        serde_json::from_str(&raw).ok()
    }

    fn read_gemini_model(&self) -> Option<String> {
        let settings = self.read_gemini_settings()?;
        value_as_string(settings.get("selectedModel"))
            .or_else(|| value_as_string(settings.get("model")))
    }

    fn fetch_zai_check_usage(&self) -> Option<CheckUsageInfo> {
        let base_url = std::env::var("ANTHROPIC_BASE_URL").ok()?;
        if !base_url.contains("api.z.ai") && !base_url.contains("bigmodel.cn") {
            return None;
        }

        let auth_token = match std::env::var("ANTHROPIC_AUTH_TOKEN").ok() {
            Some(t) if !t.trim().is_empty() => t,
            _ => return None,
        };

        let origin = extract_url_origin(&base_url)?;

        let client = match reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
        {
            Ok(c) => c,
            Err(_) => return Some(CheckUsageInfo::error_result("z.ai")),
        };

        let url = format!("{}/api/monitor/usage/quota/limit", origin);
        let response = match client
            .get(&url)
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .bearer_auth(&auth_token)
            .send()
        {
            Ok(r) => r,
            Err(_) => return Some(CheckUsageInfo::error_result("z.ai")),
        };

        if !response.status().is_success() {
            return Some(CheckUsageInfo::error_result("z.ai"));
        }

        let root: Value = match response.json() {
            Ok(v) => v,
            Err(_) => return Some(CheckUsageInfo::error_result("z.ai")),
        };

        let limits = root
            .get("data")
            .and_then(|d| d.get("limits"))
            .and_then(Value::as_array);
        let Some(limits) = limits else {
            return Some(CheckUsageInfo::error_result("z.ai"));
        };

        let mut tokens_percent: Option<f64> = None;
        let mut tokens_reset_at: Option<String> = None;
        let mut mcp_percent: Option<f64> = None;
        let mut mcp_reset_at: Option<String> = None;

        for limit in limits {
            match value_as_string(limit.get("type")).as_deref() {
                Some("TOKENS_LIMIT") => {
                    tokens_percent = limit
                        .get("currentValue")
                        .and_then(value_as_f64)
                        .map(|v| (v * 100.0).round().clamp(0.0, 100.0));
                    tokens_reset_at = value_as_string(limit.get("nextResetTime"))
                        .and_then(|s| normalize_to_iso(&s));
                }
                Some("TIME_LIMIT") => {
                    mcp_percent = limit
                        .get("usage")
                        .and_then(value_as_f64)
                        .or_else(|| limit.get("currentValue").and_then(value_as_f64))
                        .map(|v| (v * 100.0).round().clamp(0.0, 100.0));
                    mcp_reset_at = value_as_string(limit.get("nextResetTime"))
                        .and_then(|s| normalize_to_iso(&s));
                }
                _ => {}
            }
        }

        Some(CheckUsageInfo {
            name: "z.ai".to_string(),
            available: true,
            error: false,
            five_hour_percent: tokens_percent,
            seven_day_percent: mcp_percent,
            five_hour_reset: tokens_reset_at,
            seven_day_reset: mcp_reset_at,
            model: Some("GLM".to_string()),
            plan: None,
            buckets: None,
        })
    }
}

fn main() {
    if let Err(err) = run() {
        eprintln!("cauth: {}", err.message);
        std::process::exit(err.exit_code);
    }
}

fn run() -> CliResult<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = CliCommand::parse(&args)?;
    let app = CAuthApp::new(default_home_dir());

    match command {
        CliCommand::Help => {
            app.print_usage();
            Ok(())
        }
        CliCommand::List => app.list_profiles(),
        CliCommand::Status => app.status(),
        CliCommand::Save(name) => app.save_current_profile(&name),
        CliCommand::Switch(name) => app.switch_profile(&name),
        CliCommand::Refresh => app.refresh_all_profiles(),
        CliCommand::CheckUsage { account_id, json } => app.check_usage(account_id.as_deref(), json),
    }
}

fn default_home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn classify_refresh_failure(error: &CliError) -> RefreshFailure {
    let lowered = error.message.to_lowercase();
    let needs_login = lowered.contains("invalid_grant")
        || lowered.contains("refresh token not found or invalid")
        || lowered.contains("oauth token has been revoked");

    RefreshFailure {
        kind: if needs_login {
            RefreshFailureKind::NeedsLogin
        } else {
            RefreshFailureKind::Error
        },
        message: error.message.clone(),
    }
}

fn default_process_runner(executable: &str, arguments: &[String]) -> ProcessExecutionResult {
    match ProcessCommand::new(executable).args(arguments).output() {
        Ok(output) => ProcessExecutionResult {
            status: output.status.code().unwrap_or(1),
            stdout: String::from_utf8_lossy(&output.stdout).to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        },
        Err(err) => ProcessExecutionResult {
            status: 1,
            stdout: String::new(),
            stderr: err.to_string(),
        },
    }
}

fn default_refresh_client(
    token_endpoint: &str,
    oauth_client_id: &str,
    refresh_token: &str,
    scope: &str,
) -> CliResult<ClaudeRefreshPayload> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|err| CliError::new(format!("failed to build HTTP client: {}", err), 1))?;

    let body = serde_json::json!({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": oauth_client_id,
        "scope": scope,
    });
    let response = client
        .post(token_endpoint)
        .json(&body)
        .send()
        .map_err(|err| CliError::new(format!("failed to refresh token: {}", err), 1))?;
    let status = response.status();
    let text = response
        .text()
        .map_err(|err| CliError::new(format!("failed to read refresh response: {}", err), 1))?;

    if !status.is_success() {
        return Err(CliError::new(
            format!(
                "refresh failed ({}): {}",
                status.as_u16(),
                truncate_chars(&text, 200)
            ),
            1,
        ));
    }

    let root: Value = serde_json::from_str(&text)
        .map_err(|err| CliError::new(format!("refresh response is not JSON object: {}", err), 1))?;
    let access_token = value_as_string(root.get("access_token"))
        .ok_or_else(|| CliError::new("refresh response missing access_token", 1))?;

    Ok(ClaudeRefreshPayload {
        access_token,
        refresh_token: value_as_string(root.get("refresh_token")),
        expires_in: root.get("expires_in").and_then(value_as_f64),
        scope: value_as_string(root.get("scope")),
    })
}

fn default_usage_client(usage_endpoint: &str, access_token: &str) -> Option<UsageSummary> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(8))
        .build()
        .ok()?;

    let response = client
        .get(usage_endpoint)
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .header("User-Agent", "cauth/0.1")
        .header("anthropic-beta", "oauth-2025-04-20")
        .bearer_auth(access_token)
        .send()
        .ok()?;

    if !response.status().is_success() {
        return None;
    }
    let root = response.json::<Value>().ok()?;
    let (five_hour_percent, five_hour_reset) = parse_usage_window(root.get("five_hour"));
    let (seven_day_percent, seven_day_reset) = parse_usage_window(root.get("seven_day"));

    Some(UsageSummary {
        five_hour_percent,
        five_hour_reset,
        seven_day_percent,
        seven_day_reset,
    })
}

fn default_usage_raw_client(usage_endpoint: &str, access_token: &str) -> UsageRawResult {
    let request_raw = format!(
        "GET {}\nAccept: application/json\nContent-Type: application/json\nUser-Agent: cauth/0.1\nanthropic-beta: oauth-2025-04-20\nAuthorization: Bearer {}",
        usage_endpoint, access_token
    );

    let client = match reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(8))
        .build()
    {
        Ok(client) => client,
        Err(err) => {
            return UsageRawResult {
                request_raw,
                response_raw: format!("request error: failed to build HTTP client: {}", err),
            }
        }
    };

    let response = match client
        .get(usage_endpoint)
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .header("User-Agent", "cauth/0.1")
        .header("anthropic-beta", "oauth-2025-04-20")
        .bearer_auth(access_token)
        .send()
    {
        Ok(response) => response,
        Err(err) => {
            return UsageRawResult {
                request_raw,
                response_raw: format!("request error: {}", err),
            }
        }
    };

    let status_line = format!("HTTP {}", response.status());
    let header_lines = response
        .headers()
        .iter()
        .map(|(key, value)| {
            let value = value.to_str().unwrap_or("<non-utf8>");
            format!("{}: {}", key.as_str(), value)
        })
        .collect::<Vec<_>>();
    let body = match response.text() {
        Ok(text) => text,
        Err(err) => format!("<failed to read response body: {}>", err),
    };

    let response_raw = if header_lines.is_empty() {
        format!("{}\n\n{}", status_line, body)
    } else {
        format!("{}\n{}\n\n{}", status_line, header_lines.join("\n"), body)
    };

    UsageRawResult {
        request_raw,
        response_raw,
    }
}

fn parse_usage_window(value: Option<&Value>) -> (Option<i32>, Option<DateTime<Utc>>) {
    let Some(Value::Object(window)) = value else {
        return (None, None);
    };
    let percent = window
        .get("utilization")
        .and_then(value_as_f64)
        .map(|value| value.round() as i32);
    let reset_at = window.get("resets_at").and_then(parse_date_value);
    (percent, reset_at)
}

fn parse_claude_credentials(data: &[u8]) -> ClaudeCredentials {
    let root = serde_json::from_slice::<Value>(data).unwrap_or_else(|_| Value::Object(Map::new()));
    let oauth = root.get("claudeAiOauth").and_then(Value::as_object);

    let access_token = oauth
        .and_then(|object| object.get("accessToken"))
        .and_then(|value| value_as_string(Some(value)));
    let refresh_token = oauth
        .and_then(|object| object.get("refreshToken"))
        .and_then(|value| value_as_string(Some(value)));
    let expires_at = oauth
        .and_then(|object| object.get("expiresAt"))
        .and_then(parse_date_value)
        .or_else(|| {
            oauth
                .and_then(|object| object.get("expires_at"))
                .and_then(parse_date_value)
        })
        .or_else(|| root.get("expiresAt").and_then(parse_date_value))
        .or_else(|| root.get("expires_at").and_then(parse_date_value));
    let scopes = oauth
        .and_then(|object| object.get("scopes"))
        .map(normalize_scope_value)
        .unwrap_or_default();

    ClaudeCredentials {
        root,
        access_token,
        refresh_token,
        expires_at,
        scopes,
    }
}

fn ensure_oauth_object(root: &mut Value) -> CliResult<&mut Map<String, Value>> {
    if !root.is_object() {
        *root = Value::Object(Map::new());
    }
    let Some(root_map) = root.as_object_mut() else {
        return Err(CliError::new("credentials root is not object", 1));
    };

    if !root_map.contains_key("claudeAiOauth")
        || !root_map
            .get("claudeAiOauth")
            .map(Value::is_object)
            .unwrap_or(false)
    {
        root_map.insert("claudeAiOauth".to_string(), Value::Object(Map::new()));
    }

    root_map
        .get_mut("claudeAiOauth")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| CliError::new("claudeAiOauth is not object", 1))
}

fn merge_claude_metadata_value(primary: &mut Value, fallback: &Value) {
    let Some(primary_map) = primary.as_object_mut() else {
        return;
    };
    let Some(fallback_map) = fallback.as_object() else {
        return;
    };

    let metadata_keys = [
        "email",
        "account",
        "organization",
        "subscriptionType",
        "rateLimitTier",
        "isTeam",
    ];
    for key in metadata_keys {
        if let Some(value) = fallback_map.get(key) {
            let should_copy = !primary_map.contains_key(key)
                || primary_map
                    .get(key)
                    .map(|item| item.is_null())
                    .unwrap_or(true);
            if should_copy {
                primary_map.insert(key.to_string(), value.clone());
            }
        }
    }

    let mut primary_oauth = primary_map
        .get("claudeAiOauth")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let fallback_oauth = fallback_map
        .get("claudeAiOauth")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();

    for key in metadata_keys {
        if let Some(value) = fallback_oauth.get(key) {
            let should_copy = !primary_oauth.contains_key(key)
                || primary_oauth
                    .get(key)
                    .map(|item| item.is_null())
                    .unwrap_or(true);
            if should_copy {
                primary_oauth.insert(key.to_string(), value.clone());
            }
        }
    }

    primary_map.insert("claudeAiOauth".to_string(), Value::Object(primary_oauth));
}

fn extract_claude_email(root: &Value) -> Option<String> {
    let direct_paths = [
        &["email"][..],
        &["account", "email"][..],
        &["claudeAiOauth", "email"][..],
        &["claudeAiOauth", "account", "email"][..],
    ];

    for path in direct_paths {
        if let Some(email) = get_path_string(root, path).and_then(|value| normalize_email(&value)) {
            return Some(email);
        }
    }

    let access_token = get_path_string(root, &["claudeAiOauth", "accessToken"]);
    access_token
        .as_deref()
        .and_then(decode_jwt_email)
        .and_then(|email| normalize_email(&email))
}

fn resolve_claude_plan(root: &Value) -> Option<String> {
    let rate_limit_tier = get_path_string(root, &["claudeAiOauth", "rateLimitTier"])
        .or_else(|| get_path_string(root, &["rateLimitTier"]));
    let subscription_type = get_path_string(root, &["claudeAiOauth", "subscriptionType"])
        .or_else(|| get_path_string(root, &["subscriptionType"]));

    if let Some(plan) = rate_limit_tier
        .as_deref()
        .and_then(resolve_plan_from_string)
    {
        return Some(plan);
    }
    subscription_type
        .as_deref()
        .and_then(resolve_plan_from_string)
}

fn resolve_plan_from_string(raw: &str) -> Option<String> {
    let lowered = raw.to_lowercase();
    if lowered.contains("max") && lowered.contains("20") {
        return Some("Max 20x".to_string());
    }
    if lowered.contains("max") && lowered.contains("5") {
        return Some("Max 5x".to_string());
    }
    if lowered.contains("pro") {
        return Some("Pro".to_string());
    }
    if lowered.contains("max") {
        return Some("Max".to_string());
    }
    None
}

fn resolve_claude_is_team(root: &Value) -> Option<bool> {
    if let Some(value) =
        get_path_value(root, &["claudeAiOauth", "isTeam"]).and_then(parse_bool_value)
    {
        return Some(value);
    }
    if let Some(value) = get_path_value(root, &["isTeam"]).and_then(parse_bool_value) {
        return Some(value);
    }

    if get_path_string(root, &["claudeAiOauth", "subscriptionType"])
        .map(|value| value.to_lowercase().contains("team"))
        == Some(true)
    {
        return Some(true);
    }
    if get_path_string(root, &["subscriptionType"])
        .map(|value| value.to_lowercase().contains("team"))
        == Some(true)
    {
        return Some(true);
    }
    if get_path_string(
        root,
        &["claudeAiOauth", "organization", "organization_type"],
    )
    .map(|value| value.to_lowercase().contains("team"))
        == Some(true)
    {
        return Some(true);
    }
    if get_path_string(root, &["organization", "organization_type"])
        .map(|value| value.to_lowercase().contains("team"))
        == Some(true)
    {
        return Some(true);
    }

    None
}

fn parse_bool_value(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(boolean) => Some(*boolean),
        Value::Number(number) => number.as_i64().map(|raw| raw != 0),
        Value::String(raw) => {
            let lowered = raw.trim().to_lowercase();
            if lowered == "true" || lowered == "1" {
                return Some(true);
            }
            if lowered == "false" || lowered == "0" {
                return Some(false);
            }
            if lowered.contains("team") {
                return Some(true);
            }
            None
        }
        _ => None,
    }
}

fn decode_jwt_email(token: &str) -> Option<String> {
    let mut parts = token.split('.');
    let _header = parts.next()?;
    let payload = parts.next()?;
    let _signature = parts.next()?;
    if parts.next().is_some() {
        return None;
    }

    let payload_data = URL_SAFE_NO_PAD
        .decode(payload.as_bytes())
        .or_else(|_| URL_SAFE.decode(payload.as_bytes()))
        .ok()?;
    let payload_root = serde_json::from_slice::<Value>(&payload_data).ok()?;

    get_path_string(&payload_root, &["email"])
        .or_else(|| get_path_string(&payload_root, &["preferred_username"]))
}

fn normalize_email(value: &str) -> Option<String> {
    let trimmed = value.trim().to_lowercase();
    if trimmed.is_empty() || !trimmed.contains('@') {
        None
    } else {
        Some(trimmed)
    }
}

fn email_slug(email: &str) -> Option<String> {
    let mut output = String::with_capacity(email.len());
    let mut last_underscore = false;

    for character in email.to_lowercase().chars() {
        if character.is_ascii_alphanumeric() {
            output.push(character);
            last_underscore = false;
            continue;
        }
        if !last_underscore {
            output.push('_');
            last_underscore = true;
        }
    }

    let trimmed = output.trim_matches('_').to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn email_from_account_id(account_id: &str) -> Option<String> {
    let prefix = if let Some(rest) = account_id.strip_prefix("acct_claude_team_") {
        Some(rest)
    } else {
        account_id.strip_prefix("acct_claude_")
    }?;

    let (local_part, domain_slug) = prefix.split_once('_')?;
    if local_part.is_empty() || domain_slug.is_empty() {
        return None;
    }

    let domain = domain_slug.replace('_', ".");
    if domain.is_empty() {
        return None;
    }

    Some(format!("{}@{}", local_part, domain))
}

fn short_hash_hex(data: &[u8]) -> String {
    let digest = Sha256::digest(data);
    hex::encode(digest)[..16].to_string()
}

fn token_fingerprint(token: Option<&str>) -> Option<String> {
    let raw = token?.trim();
    if raw.is_empty() {
        return None;
    }
    Some(short_hash_hex(raw.as_bytes()))
}

fn next_refresh_trace_id() -> String {
    let counter = REFRESH_TRACE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let now = Utc::now()
        .timestamp_nanos_opt()
        .unwrap_or_else(|| Utc::now().timestamp_micros() * 1_000);
    let seed = format!("{}:{}:{}", now, std::process::id(), counter);
    short_hash_hex(seed.as_bytes())
}

fn process_refresh_lock_file_name(key: &str) -> String {
    let digest = Sha256::digest(key.as_bytes());
    let hex = hex::encode(digest);
    format!("usage-refresh-{}.lock", &hex[..24])
}

fn get_path_value<'a>(root: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut current = root;
    for segment in path {
        current = current.get(*segment)?;
    }
    Some(current)
}

fn get_path_string(root: &Value, path: &[&str]) -> Option<String> {
    value_as_string(get_path_value(root, path))
}

fn value_as_string(value: Option<&Value>) -> Option<String> {
    match value {
        Some(Value::String(raw)) => {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        _ => None,
    }
}

fn value_as_f64(value: &Value) -> Option<f64> {
    match value {
        Value::Number(number) => number.as_f64(),
        Value::String(raw) => raw.trim().parse::<f64>().ok(),
        _ => None,
    }
}

fn normalize_scope_value(value: &Value) -> Vec<String> {
    match value {
        Value::Array(list) => list
            .iter()
            .filter_map(|item| value_as_string(Some(item)))
            .collect(),
        Value::String(raw) => normalize_scope_string(raw),
        _ => Vec::new(),
    }
}

fn normalize_scope_string(raw: &str) -> Vec<String> {
    raw.split(' ')
        .map(|item| item.trim())
        .filter(|item| !item.is_empty())
        .map(|item| item.to_string())
        .collect()
}

fn parse_date_value(value: &Value) -> Option<DateTime<Utc>> {
    match value {
        Value::Number(number) => number.as_f64().and_then(date_from_timestamp),
        Value::String(raw) => {
            if let Ok(number) = raw.trim().parse::<f64>() {
                return date_from_timestamp(number);
            }
            DateTime::parse_from_rfc3339(raw)
                .ok()
                .map(|date| date.with_timezone(&Utc))
        }
        _ => None,
    }
}

fn date_from_timestamp(timestamp: f64) -> Option<DateTime<Utc>> {
    if !timestamp.is_finite() || timestamp <= 0.0 {
        return None;
    }

    let milliseconds = if timestamp > 1_000_000_000_000.0 {
        timestamp
    } else if timestamp > 1_000_000_000.0 {
        timestamp * 1000.0
    } else {
        return None;
    };
    DateTime::<Utc>::from_timestamp_millis(milliseconds.round() as i64)
}

fn format_usage_window(percent: Option<i32>, reset_at: Option<&DateTime<Utc>>) -> String {
    let percent_text = percent
        .map(|value| format!("{}%", value))
        .unwrap_or_else(|| "--".to_string());
    let reset_text = reset_at
        .map(format_time_remaining)
        .unwrap_or_else(|| "--".to_string());
    format!("{} ({})", percent_text, reset_text)
}

fn format_time_remaining(date: &DateTime<Utc>) -> String {
    let remaining = (*date - Utc::now()).num_seconds();
    if remaining <= 0 {
        return "expired".to_string();
    }
    format_duration(remaining)
}

fn format_key_remaining(expires_at: Option<&DateTime<Utc>>) -> String {
    let Some(expires_at) = expires_at else {
        return "--".to_string();
    };
    let remaining = (*expires_at - Utc::now()).num_seconds();
    if remaining <= 0 {
        return "expired".to_string();
    }
    format_duration(remaining)
}

fn format_duration(seconds: i64) -> String {
    let days = seconds / 86_400;
    let hours = (seconds % 86_400) / 3_600;
    let minutes = (seconds % 3_600) / 60;
    if days > 0 {
        format!("{}d {}h {}m", days, hours, minutes)
    } else {
        format!("{}h {}m", hours, minutes)
    }
}

fn utc_now_iso() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn refresh_lock_id_from_credentials_data(data: &[u8]) -> Option<String> {
    let parsed = parse_claude_credentials(data);
    let refresh_token = parsed.refresh_token?;
    Some(short_hash_hex(refresh_token.as_bytes()))
}

fn upsert_account(snapshot: &mut AccountsSnapshot, account: UsageAccount) {
    if let Some(index) = snapshot
        .accounts
        .iter()
        .position(|item| item.id == account.id)
    {
        snapshot.accounts[index] = account;
    } else {
        snapshot.accounts.push(account);
    }
}

fn upsert_profile(snapshot: &mut AccountsSnapshot, profile: UsageProfile) {
    if let Some(index) = snapshot
        .profiles
        .iter()
        .position(|item| item.name == profile.name)
    {
        snapshot.profiles[index] = profile;
    } else {
        snapshot.profiles.push(profile);
    }
}

fn write_file_atomic(path: &Path, data: &[u8]) -> CliResult<()> {
    let parent = path
        .parent()
        .ok_or_else(|| CliError::new(format!("invalid target path: {}", path.display()), 1))?;
    fs::create_dir_all(parent).map_err(|err| {
        CliError::new(
            format!("failed to create dir {}: {}", parent.display(), err),
            1,
        )
    })?;

    let mut temp_file = NamedTempFile::new_in(parent)
        .map_err(|err| CliError::new(format!("failed to create temp file: {}", err), 1))?;
    temp_file
        .write_all(data)
        .map_err(|err| CliError::new(format!("failed to write temp file: {}", err), 1))?;
    let _ = temp_file
        .as_file()
        .set_permissions(fs::Permissions::from_mode(0o600));

    temp_file.persist(path).map_err(|err| {
        CliError::new(format!("failed to persist {}: {}", path.display(), err), 1)
    })?;
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    Ok(())
}

fn truncate_chars(raw: &str, max_chars: usize) -> String {
    raw.chars().take(max_chars).collect::<String>()
}

fn normalize_to_iso(date_str: &str) -> Option<String> {
    if let Ok(dt) = DateTime::parse_from_rfc3339(date_str) {
        return Some(
            dt.with_timezone(&Utc)
                .to_rfc3339_opts(SecondsFormat::Millis, true),
        );
    }
    if let Ok(ts) = date_str.parse::<f64>() {
        return date_from_timestamp(ts).map(|d| d.to_rfc3339_opts(SecondsFormat::Millis, true));
    }
    None
}

fn extract_url_origin(url: &str) -> Option<String> {
    let scheme_end = url.find("://")?;
    let after_scheme = &url[scheme_end + 3..];
    let host_end = after_scheme.find('/').unwrap_or(after_scheme.len());
    Some(format!(
        "{}{}",
        &url[..scheme_end + 3],
        &after_scheme[..host_end]
    ))
}

fn compute_check_usage_recommendation(
    claude: &CheckUsageInfo,
    codex: Option<&CheckUsageInfo>,
    gemini: Option<&CheckUsageInfo>,
    zai: Option<&CheckUsageInfo>,
) -> (Option<String>, String) {
    let mut candidates: Vec<(&str, f64)> = Vec::new();

    if !claude.error {
        if let Some(percent) = claude.five_hour_percent {
            candidates.push(("claude", percent));
        }
    }
    if let Some(info) = codex {
        if info.available && !info.error {
            if let Some(percent) = info.five_hour_percent {
                candidates.push(("codex", percent));
            }
        }
    }
    if let Some(info) = gemini {
        if info.available && !info.error {
            if let Some(percent) = info.five_hour_percent {
                candidates.push(("gemini", percent));
            }
        }
    }
    if let Some(info) = zai {
        if info.available && !info.error {
            if let Some(percent) = info.five_hour_percent {
                candidates.push(("z.ai", percent));
            }
        }
    }

    if candidates.is_empty() {
        return (None, "No usage data available".to_string());
    }

    candidates.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
    let best = candidates[0];
    (
        Some(best.0.to_string()),
        format!("Lowest usage ({}% used)", best.1 as i32),
    )
}

fn render_raw_credential(data: &[u8]) -> String {
    match std::str::from_utf8(data) {
        Ok(text) => text.to_string(),
        Err(_) => format!("<non-utf8 credential bytes: {}>", data.len()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use tempfile::TempDir;

    #[test]
    fn parse_supports_status_command() {
        let command =
            CliCommand::parse(&["status".to_string()]).expect("status command should parse");
        assert!(matches!(command, CliCommand::Status));
    }

    #[test]
    fn status_report_lines_include_raw_credential_request_and_response_for_keychain_and_file() {
        let temp = TempDir::new().expect("temp dir");
        let home = temp.path().to_path_buf();
        let active_path = home.join(".claude/.credentials.json");
        write_credentials(
            &active_path,
            "at-file",
            "rt-file",
            1_800_000_000_000,
            Some("file@example.com"),
            None,
        )
        .expect("write file credential");

        let keychain_json = serde_json::json!({
            "claudeAiOauth": {
                "accessToken": "at-keychain",
                "refreshToken": "rt-keychain",
                "expiresAt": 1_800_001_000_000i64,
                "scopes": ["user:profile"]
            }
        })
        .to_string();
        let keychain_for_runner = keychain_json.clone();
        let process_runner: ProcessRunner = Arc::new(move |executable, arguments| {
            if !executable.ends_with("security") {
                return ProcessExecutionResult {
                    status: 1,
                    stdout: String::new(),
                    stderr: "unexpected executable".to_string(),
                };
            }
            if arguments.first().map(|value| value.as_str()) == Some("find-generic-password")
                && arguments.iter().any(|value| value == "-w")
            {
                return ProcessExecutionResult {
                    status: 0,
                    stdout: keychain_for_runner.clone(),
                    stderr: String::new(),
                };
            }
            ProcessExecutionResult {
                status: 1,
                stdout: String::new(),
                stderr: "unsupported".to_string(),
            }
        });

        let seen_tokens = Arc::new(Mutex::new(Vec::<String>::new()));
        let seen_tokens_ref = Arc::clone(&seen_tokens);
        let usage_raw_client: UsageRawClient = Arc::new(move |access_token| {
            if let Ok(mut list) = seen_tokens_ref.lock() {
                list.push(access_token.to_string());
            }
            UsageRawResult {
                request_raw: format!("RAW-REQ token={}", access_token),
                response_raw: format!("RAW-RESP token={}", access_token),
            }
        });

        let app = CAuthApp::with_clients_and_usage_raw(
            home,
            process_runner,
            Arc::new(|_, _| Err(CliError::new("refresh should not run", 1))),
            Arc::new(|_| None),
            usage_raw_client,
        );

        let lines = app.status_report_lines();
        let joined = lines.join("\n");
        assert!(joined.contains("Source: osxkeychain"));
        assert!(joined.contains("Raw Credential:"));
        assert!(joined.contains("rt-keychain"));
        assert!(joined.contains("RAW-REQ token=at-keychain"));
        assert!(joined.contains("RAW-RESP token=at-keychain"));
        assert!(joined.contains("Source: ~/.claude/.credentials.json"));
        assert!(joined.contains("rt-file"));
        assert!(joined.contains("RAW-REQ token=at-file"));
        assert!(joined.contains("RAW-RESP token=at-file"));

        let tokens = seen_tokens.lock().expect("tokens").clone();
        assert_eq!(tokens.len(), 2);
        assert!(tokens.contains(&"at-keychain".to_string()));
        assert!(tokens.contains(&"at-file".to_string()));
    }

    #[test]
    fn list_logs_email_resolution_source_for_traceability() {
        let temp = TempDir::new().expect("temp dir");
        let home = temp.path().to_path_buf();

        let account_id = "acct_claude_home_example_com";
        let account_root = home.join(format!(".agent-island/accounts/{}", account_id));
        let stored_path = account_root.join(".claude/.credentials.json");
        write_credentials(
            &stored_path,
            "at-list",
            "rt-list",
            1_800_000_000_000,
            None,
            None,
        )
        .expect("write stored credentials");

        let store = AccountStore::new(home.join(".agent-island"));
        let snapshot = AccountsSnapshot {
            accounts: vec![UsageAccount {
                id: account_id.to_string(),
                service: UsageService::Claude,
                label: "claude:test".to_string(),
                root_path: account_root.display().to_string(),
                updated_at: utc_now_iso(),
            }],
            profiles: vec![UsageProfile {
                name: "home".to_string(),
                claude_account_id: Some(account_id.to_string()),
                codex_account_id: None,
                gemini_account_id: None,
            }],
        };
        store.save_snapshot(&snapshot).expect("save snapshot");

        let recorder = ProcessRecorder::default();
        let app = CAuthApp::with_clients(
            home.clone(),
            recorder.runner(),
            Arc::new(|_, _| Err(CliError::new("refresh should not run", 1))),
            Arc::new(|_| None),
        );

        let _ = app.profile_inventory_lines().expect("list lines");
        let log_path = home.join(".agent-island/logs/usage-refresh.log");
        let content = fs::read_to_string(&log_path).expect("read log");
        assert!(content.contains("\"event\":\"cauth_email_resolution\""));
        assert!(content.contains("\"email_source\":\"account_id_fallback\""));
        assert!(content.contains("\"email\":\"home@example.com\""));
    }

    #[test]
    fn save_creates_email_based_account_and_profile_mapping() {
        let temp = TempDir::new().expect("temp dir");
        let home = temp.path().to_path_buf();
        let active_path = home.join(".claude/.credentials.json");
        write_credentials(
            &active_path,
            "at-original",
            "rt-original",
            1_800_000_000_000,
            Some("z@iq.io"),
            Some(true),
        )
        .expect("write active credentials");

        let recorder = ProcessRecorder::default();
        let app = CAuthApp::with_clients(
            home.clone(),
            recorder.runner(),
            Arc::new(|_, _| {
                Err(CliError::new(
                    "refresh client should not be called in save test",
                    1,
                ))
            }),
            Arc::new(|_| None),
        );

        app.save_current_profile("home").expect("save profile");

        let account_id = "acct_claude_team_z_iq_io";
        let stored_path = home.join(format!(
            ".agent-island/accounts/{}/.claude/.credentials.json",
            account_id
        ));
        assert!(
            stored_path.exists(),
            "stored profile credential should exist"
        );

        let snapshot = AccountStore::new(home.join(".agent-island"))
            .load_snapshot()
            .expect("load snapshot");
        let profile = snapshot
            .profiles
            .iter()
            .find(|item| item.name == "home")
            .expect("profile home");
        assert_eq!(profile.claude_account_id.as_deref(), Some(account_id));
    }

    #[test]
    fn load_current_prefers_keychain_and_merges_metadata_from_matching_file() {
        let temp = TempDir::new().expect("temp dir");
        let home = temp.path().to_path_buf();
        let active_path = home.join(".claude/.credentials.json");
        write_credentials(
            &active_path,
            "at-file",
            "rt-shared",
            1_800_000_000_000,
            Some("z@iq.io"),
            Some(true),
        )
        .expect("write file credentials");

        let keychain_raw = serde_json::json!({
            "claudeAiOauth": {
                "accessToken": "at-keychain",
                "refreshToken": "rt-shared",
                "expiresAt": 1_800_001_000_000i64,
                "scopes": ["user:profile"]
            }
        })
        .to_string();
        let keychain_for_find = keychain_raw.clone();

        let process_runner: ProcessRunner = Arc::new(move |executable, arguments| {
            if !executable.ends_with("security") {
                return ProcessExecutionResult {
                    status: 1,
                    stdout: String::new(),
                    stderr: "unexpected executable".to_string(),
                };
            }
            let Some(command) = arguments.first() else {
                return ProcessExecutionResult {
                    status: 1,
                    stdout: String::new(),
                    stderr: "missing command".to_string(),
                };
            };
            if command == "find-generic-password" && arguments.iter().any(|arg| arg == "-w") {
                return ProcessExecutionResult {
                    status: 0,
                    stdout: keychain_for_find.clone(),
                    stderr: String::new(),
                };
            }
            if command == "find-generic-password" && arguments.iter().any(|arg| arg == "-g") {
                return ProcessExecutionResult {
                    status: 0,
                    stdout: String::new(),
                    stderr: "keychain: \"acct\"<blob>=\"tester\"\n".to_string(),
                };
            }
            ProcessExecutionResult {
                status: 0,
                stdout: String::new(),
                stderr: String::new(),
            }
        });

        let app = CAuthApp::with_clients(
            home,
            process_runner,
            Arc::new(|_, _| Err(CliError::new("refresh should not run", 1))),
            Arc::new(|_| None),
        );

        let current = app
            .load_current_credentials()
            .expect("should load current credentials");
        let parsed = parse_claude_credentials(&current);
        assert_eq!(parsed.access_token.as_deref(), Some("at-keychain"));
        assert_eq!(parsed.refresh_token.as_deref(), Some("rt-shared"));
        assert_eq!(
            extract_claude_email(&parsed.root).as_deref(),
            Some("z@iq.io")
        );
        assert_eq!(resolve_claude_is_team(&parsed.root), Some(true));
        assert_eq!(
            app.resolve_claude_account_id(&current),
            "acct_claude_team_z_iq_io".to_string()
        );
    }

    #[test]
    fn refresh_lock_keys_match_usage_fetcher_shape() {
        let temp = TempDir::new().expect("temp dir");
        let home = temp.path().to_path_buf();
        let recorder = ProcessRecorder::default();
        let app = CAuthApp::with_clients(
            home.clone(),
            recorder.runner(),
            Arc::new(|_, _| Err(CliError::new("refresh should not run", 1))),
            Arc::new(|_| None),
        );

        let credential_path = home.join(".agent-island/accounts/acct/.claude/.credentials.json");
        let data = serde_json::to_vec_pretty(&serde_json::json!({
            "claudeAiOauth": {
                "accessToken": "at-lock",
                "refreshToken": "rt-lock",
                "expiresAt": 1_800_000_000_000i64,
                "subscriptionType": "max",
                "scopes": ["user:profile"]
            },
            "email": "lock@example.com"
        }))
        .expect("credential data");

        let keys =
            app.refresh_lock_keys(&data, "acct_claude_lock", Some(credential_path.as_path()));
        assert!(
            keys.contains(&credential_path.display().to_string()),
            "expected credential path key in lock keys: {:?}",
            keys
        );
        assert!(
            keys.contains(&format!(
                "claude-refresh-token:{}",
                short_hash_hex("rt-lock".as_bytes())
            )),
            "expected refresh-token fingerprint key in lock keys: {:?}",
            keys
        );

        let file_name = process_refresh_lock_file_name("claude-refresh-token:test");
        assert!(file_name.starts_with("usage-refresh-"));
        assert!(file_name.ends_with(".lock"));
        assert_eq!(file_name.len(), "usage-refresh-".len() + 24 + ".lock".len());
    }

    #[test]
    fn refresh_log_writer_uses_shared_usage_refresh_log_file() {
        let temp = TempDir::new().expect("temp dir");
        let log_dir = temp.path().join(".agent-island/logs");
        let writer = CAuthRefreshLogWriter::new(log_dir.clone());
        writer.write(
            "cauth_refresh_result",
            &[
                ("trace_id", Some("trace-1".to_string())),
                ("account_id", Some("acct_claude_test".to_string())),
                ("decision", Some("success".to_string())),
            ],
        );

        let log_path = log_dir.join("usage-refresh.log");
        let content = fs::read_to_string(log_path).expect("read log");
        assert!(content.contains("\"event\":\"cauth_refresh_result\""));
        assert!(content.contains("\"trace_id\":\"trace-1\""));
        assert!(content.contains("\"account_id\":\"acct_claude_test\""));
    }

    #[test]
    fn list_profiles_shows_saved_profiles_and_current_marker() {
        let temp = TempDir::new().expect("temp dir");
        let home = temp.path().to_path_buf();
        let account_id = "acct_claude_home_example_com";
        let account_root = home.join(format!(".agent-island/accounts/{}", account_id));
        let stored_path = account_root.join(".claude/.credentials.json");
        write_credentials(
            &stored_path,
            "at-list",
            "rt-list",
            1_800_000_000_000,
            Some("home@example.com"),
            None,
        )
        .expect("write stored credentials");
        write_credentials(
            &home.join(".claude/.credentials.json"),
            "at-list",
            "rt-list",
            1_800_000_000_000,
            Some("home@example.com"),
            None,
        )
        .expect("write active credentials");

        let store = AccountStore::new(home.join(".agent-island"));
        let snapshot = AccountsSnapshot {
            accounts: vec![UsageAccount {
                id: account_id.to_string(),
                service: UsageService::Claude,
                label: "claude:test".to_string(),
                root_path: account_root.display().to_string(),
                updated_at: utc_now_iso(),
            }],
            profiles: vec![UsageProfile {
                name: "home".to_string(),
                claude_account_id: Some(account_id.to_string()),
                codex_account_id: None,
                gemini_account_id: None,
            }],
        };
        store.save_snapshot(&snapshot).expect("save snapshot");

        let recorder = ProcessRecorder::default();
        let app = CAuthApp::with_clients(
            home,
            recorder.runner(),
            Arc::new(|_, _| {
                Err(CliError::new(
                    "refresh client should not be called in list test",
                    1,
                ))
            }),
            Arc::new(|_| None),
        );

        let lines = app.profile_inventory_lines().expect("list lines");
        let combined = lines.join("\n");
        assert!(combined.contains("Profiles:"));
        assert!(combined.contains("Accounts:"));
        assert!(combined.contains("home@example.com"));
        assert!(combined.contains("acct_claude_home_example_com"));
        assert!(combined.contains("[current]"));
    }

    #[test]
    fn switch_writes_active_credentials_and_keychain() {
        let temp = TempDir::new().expect("temp dir");
        let home = temp.path().to_path_buf();
        let account_id = "acct_claude_home_example_com";
        let account_root = home.join(format!(".agent-island/accounts/{}", account_id));
        let stored_path = account_root.join(".claude/.credentials.json");
        write_credentials(
            &stored_path,
            "at-switched",
            "rt-switched",
            1_800_000_000_000,
            Some("home@example.com"),
            None,
        )
        .expect("write stored credentials");

        let store = AccountStore::new(home.join(".agent-island"));
        let snapshot = AccountsSnapshot {
            accounts: vec![UsageAccount {
                id: account_id.to_string(),
                service: UsageService::Claude,
                label: "claude:test".to_string(),
                root_path: account_root.display().to_string(),
                updated_at: utc_now_iso(),
            }],
            profiles: vec![UsageProfile {
                name: "home".to_string(),
                claude_account_id: Some(account_id.to_string()),
                codex_account_id: None,
                gemini_account_id: None,
            }],
        };
        store.save_snapshot(&snapshot).expect("save snapshot");

        let recorder = ProcessRecorder::default();
        let app = CAuthApp::with_clients(
            home.clone(),
            recorder.runner(),
            Arc::new(|_, _| {
                Err(CliError::new(
                    "refresh client should not be called in switch test",
                    1,
                ))
            }),
            Arc::new(|_| None),
        );

        app.switch_profile("home").expect("switch profile");
        let active_tokens =
            read_tokens(&home.join(".claude/.credentials.json")).expect("read active tokens");
        assert_eq!(active_tokens.0.as_deref(), Some("at-switched"));
        assert_eq!(active_tokens.1.as_deref(), Some("rt-switched"));
        assert_eq!(recorder.add_count(), 1);
        assert!(recorder
            .last_added_secret()
            .unwrap_or_default()
            .contains("at-switched"));
    }

    #[test]
    fn refresh_updates_stored_and_active_and_keychain() {
        let temp = TempDir::new().expect("temp dir");
        let home = temp.path().to_path_buf();
        let account_id = "acct_claude_home_example_com";
        let account_root = home.join(format!(".agent-island/accounts/{}", account_id));
        let account_path = account_root.join(".claude/.credentials.json");
        let active_path = home.join(".claude/.credentials.json");

        write_credentials(
            &account_path,
            "at-before",
            "rt-before",
            1_700_000_000_000,
            Some("home@example.com"),
            None,
        )
        .expect("write account creds");
        write_credentials(
            &active_path,
            "at-before",
            "rt-before",
            1_700_000_000_000,
            Some("home@example.com"),
            None,
        )
        .expect("write active creds");

        let store = AccountStore::new(home.join(".agent-island"));
        let snapshot = AccountsSnapshot {
            accounts: vec![UsageAccount {
                id: account_id.to_string(),
                service: UsageService::Claude,
                label: "claude:test".to_string(),
                root_path: account_root.display().to_string(),
                updated_at: utc_now_iso(),
            }],
            profiles: vec![UsageProfile {
                name: "home".to_string(),
                claude_account_id: Some(account_id.to_string()),
                codex_account_id: None,
                gemini_account_id: None,
            }],
        };
        store.save_snapshot(&snapshot).expect("save snapshot");

        let recorder = ProcessRecorder::default();
        let refresh_count = Arc::new(Mutex::new(0_usize));
        let refresh_count_ref = Arc::clone(&refresh_count);
        let refresh_client: RefreshClient = Arc::new(move |refresh_token, _| {
            let mut count = refresh_count_ref.lock().expect("lock refresh count");
            *count += 1;
            assert_eq!(refresh_token, "rt-before");
            Ok(ClaudeRefreshPayload {
                access_token: "at-after".to_string(),
                refresh_token: Some("rt-after".to_string()),
                expires_in: Some(28_800.0),
                scope: Some("user:profile user:inference".to_string()),
            })
        });
        let usage_client: UsageClient = Arc::new(|_| {
            Some(UsageSummary {
                five_hour_percent: Some(91),
                five_hour_reset: DateTime::<Utc>::from_timestamp(1_900_000_000, 0),
                seven_day_percent: Some(65),
                seven_day_reset: DateTime::<Utc>::from_timestamp(1_900_010_000, 0),
            })
        });

        let app = CAuthApp::with_clients(
            home.clone(),
            recorder.runner(),
            refresh_client,
            usage_client,
        );
        app.refresh_all_profiles().expect("refresh profiles");

        let stored_tokens = read_tokens(&account_path).expect("stored tokens");
        let active_tokens = read_tokens(&active_path).expect("active tokens");
        assert_eq!(stored_tokens.0.as_deref(), Some("at-after"));
        assert_eq!(stored_tokens.1.as_deref(), Some("rt-after"));
        assert_eq!(active_tokens.0.as_deref(), Some("at-after"));
        assert_eq!(active_tokens.1.as_deref(), Some("rt-after"));
        assert_eq!(*refresh_count.lock().expect("refresh count"), 1);
        assert_eq!(recorder.add_count(), 1);
    }

    #[test]
    fn check_usage_account_mode_does_not_mutate_active_credentials() {
        let temp = TempDir::new().expect("temp dir");
        let home = temp.path().to_path_buf();
        let account_id = "acct_claude_home_example_com";
        let account_root = home.join(format!(".agent-island/accounts/{}", account_id));
        let account_path = account_root.join(".claude/.credentials.json");
        let active_path = home.join(".claude/.credentials.json");

        write_credentials(
            &account_path,
            "at-account-before",
            "rt-account-before",
            1_700_000_000_000,
            Some("home@example.com"),
            None,
        )
        .expect("write account credential");
        write_credentials(
            &active_path,
            "at-active-before",
            "rt-active-before",
            1_700_000_000_000,
            Some("active@example.com"),
            None,
        )
        .expect("write active credential");

        let store = AccountStore::new(home.join(".agent-island"));
        let snapshot = AccountsSnapshot {
            accounts: vec![UsageAccount {
                id: account_id.to_string(),
                service: UsageService::Claude,
                label: "claude:test".to_string(),
                root_path: account_root.display().to_string(),
                updated_at: utc_now_iso(),
            }],
            profiles: vec![UsageProfile {
                name: "home".to_string(),
                claude_account_id: Some(account_id.to_string()),
                codex_account_id: None,
                gemini_account_id: None,
            }],
        };
        store.save_snapshot(&snapshot).expect("save snapshot");

        let recorder = ProcessRecorder::default();
        let refresh_client: RefreshClient = Arc::new(move |refresh_token, _| {
            assert_eq!(refresh_token, "rt-account-before");
            Ok(ClaudeRefreshPayload {
                access_token: "at-account-after".to_string(),
                refresh_token: Some("rt-account-after".to_string()),
                expires_in: Some(28_800.0),
                scope: Some("user:profile".to_string()),
            })
        });
        let usage_client: UsageClient = Arc::new(|_| {
            Some(UsageSummary {
                five_hour_percent: Some(42),
                five_hour_reset: DateTime::<Utc>::from_timestamp(1_900_000_000, 0),
                seven_day_percent: Some(21),
                seven_day_reset: DateTime::<Utc>::from_timestamp(1_900_010_000, 0),
            })
        });

        let app = CAuthApp::with_clients(
            home.clone(),
            recorder.runner(),
            refresh_client,
            usage_client,
        );
        app.check_usage(Some(account_id), true)
            .expect("check-usage --account");

        let account_tokens = read_tokens(&account_path).expect("account tokens");
        let active_tokens = read_tokens(&active_path).expect("active tokens");
        assert_eq!(account_tokens.0.as_deref(), Some("at-account-after"));
        assert_eq!(account_tokens.1.as_deref(), Some("rt-account-after"));
        assert_eq!(active_tokens.0.as_deref(), Some("at-active-before"));
        assert_eq!(active_tokens.1.as_deref(), Some("rt-active-before"));
        assert_eq!(recorder.add_count(), 0);
    }

    #[test]
    fn refresh_dedupes_by_refresh_token_for_legacy_duplicate_accounts() {
        let temp = TempDir::new().expect("temp dir");
        let home = temp.path().to_path_buf();
        let account_a = "acct_claude_legacy_a";
        let account_b = "acct_claude_legacy_b";
        let root_a = home.join(format!(".agent-island/accounts/{}", account_a));
        let root_b = home.join(format!(".agent-island/accounts/{}", account_b));
        let path_a = root_a.join(".claude/.credentials.json");
        let path_b = root_b.join(".claude/.credentials.json");

        write_credentials(&path_a, "at-a", "rt-shared", 1_700_000_000_000, None, None)
            .expect("write path a");
        write_credentials(&path_b, "at-b", "rt-shared", 1_700_000_000_000, None, None)
            .expect("write path b");

        let store = AccountStore::new(home.join(".agent-island"));
        let snapshot = AccountsSnapshot {
            accounts: vec![
                UsageAccount {
                    id: account_a.to_string(),
                    service: UsageService::Claude,
                    label: "claude:a".to_string(),
                    root_path: root_a.display().to_string(),
                    updated_at: utc_now_iso(),
                },
                UsageAccount {
                    id: account_b.to_string(),
                    service: UsageService::Claude,
                    label: "claude:b".to_string(),
                    root_path: root_b.display().to_string(),
                    updated_at: utc_now_iso(),
                },
            ],
            profiles: vec![
                UsageProfile {
                    name: "home".to_string(),
                    claude_account_id: Some(account_a.to_string()),
                    codex_account_id: None,
                    gemini_account_id: None,
                },
                UsageProfile {
                    name: "work1".to_string(),
                    claude_account_id: Some(account_b.to_string()),
                    codex_account_id: None,
                    gemini_account_id: None,
                },
            ],
        };
        store.save_snapshot(&snapshot).expect("save snapshot");

        let recorder = ProcessRecorder::default();
        let refresh_count = Arc::new(Mutex::new(0_usize));
        let refresh_count_ref = Arc::clone(&refresh_count);
        let refresh_client: RefreshClient = Arc::new(move |_, _| {
            let mut count = refresh_count_ref.lock().expect("lock refresh count");
            *count += 1;
            Ok(ClaudeRefreshPayload {
                access_token: "at-deduped".to_string(),
                refresh_token: Some("rt-deduped".to_string()),
                expires_in: Some(28_800.0),
                scope: Some("user:profile".to_string()),
            })
        });
        let app = CAuthApp::with_clients(
            home.clone(),
            recorder.runner(),
            refresh_client,
            Arc::new(|_| None),
        );

        app.refresh_all_profiles().expect("refresh profiles");
        let a_tokens = read_tokens(&path_a).expect("tokens a");
        let b_tokens = read_tokens(&path_b).expect("tokens b");
        assert_eq!(a_tokens.0.as_deref(), Some("at-deduped"));
        assert_eq!(a_tokens.1.as_deref(), Some("rt-deduped"));
        assert_eq!(b_tokens.0.as_deref(), Some("at-deduped"));
        assert_eq!(b_tokens.1.as_deref(), Some("rt-deduped"));
        assert_eq!(*refresh_count.lock().expect("refresh count"), 1);
    }

    #[test]
    fn refresh_continues_when_one_profile_invalid_grant() {
        let temp = TempDir::new().expect("temp dir");
        let home = temp.path().to_path_buf();
        let good_account = "acct_claude_good_example_com";
        let bad_account = "acct_claude_bad_example_com";
        let good_root = home.join(format!(".agent-island/accounts/{}", good_account));
        let bad_root = home.join(format!(".agent-island/accounts/{}", bad_account));
        let good_path = good_root.join(".claude/.credentials.json");
        let bad_path = bad_root.join(".claude/.credentials.json");

        write_credentials(
            &good_path,
            "at-good-before",
            "rt-good-before",
            1_700_000_000_000,
            Some("good@example.com"),
            None,
        )
        .expect("write good credential");
        write_credentials(
            &bad_path,
            "at-bad-before",
            "rt-bad-before",
            1_700_000_000_000,
            Some("bad@example.com"),
            None,
        )
        .expect("write bad credential");
        write_credentials(
            &home.join(".claude/.credentials.json"),
            "at-good-before",
            "rt-good-before",
            1_700_000_000_000,
            Some("good@example.com"),
            None,
        )
        .expect("write active credential");

        let store = AccountStore::new(home.join(".agent-island"));
        let snapshot = AccountsSnapshot {
            accounts: vec![
                UsageAccount {
                    id: good_account.to_string(),
                    service: UsageService::Claude,
                    label: "claude:good".to_string(),
                    root_path: good_root.display().to_string(),
                    updated_at: utc_now_iso(),
                },
                UsageAccount {
                    id: bad_account.to_string(),
                    service: UsageService::Claude,
                    label: "claude:bad".to_string(),
                    root_path: bad_root.display().to_string(),
                    updated_at: utc_now_iso(),
                },
            ],
            profiles: vec![
                UsageProfile {
                    name: "home".to_string(),
                    claude_account_id: Some(good_account.to_string()),
                    codex_account_id: None,
                    gemini_account_id: None,
                },
                UsageProfile {
                    name: "work3".to_string(),
                    claude_account_id: Some(bad_account.to_string()),
                    codex_account_id: None,
                    gemini_account_id: None,
                },
            ],
        };
        store.save_snapshot(&snapshot).expect("save snapshot");

        let recorder = ProcessRecorder::default();
        let refresh_client: RefreshClient = Arc::new(move |refresh_token, _| {
            if refresh_token == "rt-bad-before" {
                return Err(CliError::new(
                    "refresh failed (400): {\"error\":\"invalid_grant\",\"error_description\":\"Refresh token not found or invalid\"}",
                    1,
                ));
            }

            Ok(ClaudeRefreshPayload {
                access_token: "at-good-after".to_string(),
                refresh_token: Some("rt-good-after".to_string()),
                expires_in: Some(28_800.0),
                scope: Some("user:profile".to_string()),
            })
        });
        let app = CAuthApp::with_clients(
            home.clone(),
            recorder.runner(),
            refresh_client,
            Arc::new(|_| None),
        );

        let err = app
            .refresh_all_profiles()
            .expect_err("one profile should fail with invalid_grant");
        assert!(
            err.message.contains("need login"),
            "unexpected error: {}",
            err.message
        );
        assert!(
            err.message.contains("work3"),
            "should include failing profile name: {}",
            err.message
        );

        let good_tokens = read_tokens(&good_path).expect("good tokens");
        let bad_tokens = read_tokens(&bad_path).expect("bad tokens");
        assert_eq!(good_tokens.0.as_deref(), Some("at-good-after"));
        assert_eq!(good_tokens.1.as_deref(), Some("rt-good-after"));
        assert_eq!(bad_tokens.0.as_deref(), Some("at-bad-before"));
        assert_eq!(bad_tokens.1.as_deref(), Some("rt-bad-before"));
        assert_eq!(recorder.add_count(), 1);
    }

    fn write_credentials(
        path: &Path,
        access_token: &str,
        refresh_token: &str,
        expires_at_millis: i64,
        email: Option<&str>,
        is_team: Option<bool>,
    ) -> CliResult<()> {
        let mut oauth = Map::new();
        oauth.insert(
            "accessToken".to_string(),
            Value::String(access_token.to_string()),
        );
        oauth.insert(
            "refreshToken".to_string(),
            Value::String(refresh_token.to_string()),
        );
        oauth.insert(
            "expiresAt".to_string(),
            Value::Number(expires_at_millis.into()),
        );
        oauth.insert(
            "subscriptionType".to_string(),
            Value::String("max".to_string()),
        );
        oauth.insert(
            "rateLimitTier".to_string(),
            Value::String("default_claude_max_20x".to_string()),
        );
        oauth.insert(
            "scopes".to_string(),
            Value::Array(vec![
                Value::String("user:profile".to_string()),
                Value::String("user:inference".to_string()),
            ]),
        );
        if let Some(email) = email {
            oauth.insert("email".to_string(), Value::String(email.to_string()));
        }
        if let Some(is_team) = is_team {
            oauth.insert("isTeam".to_string(), Value::Bool(is_team));
        }

        let mut root = Map::new();
        root.insert("claudeAiOauth".to_string(), Value::Object(oauth));
        let data = serde_json::to_vec_pretty(&Value::Object(root)).map_err(|err| {
            CliError::new(format!("failed to encode test credential: {}", err), 1)
        })?;
        write_file_atomic(path, &data)
    }

    fn read_tokens(path: &Path) -> CliResult<(Option<String>, Option<String>)> {
        let data = fs::read(path).map_err(|err| {
            CliError::new(
                format!("failed to read credential {}: {}", path.display(), err),
                1,
            )
        })?;
        let root: Value = serde_json::from_slice(&data)
            .map_err(|err| CliError::new(format!("failed to parse credential JSON: {}", err), 1))?;
        let access_token = get_path_string(&root, &["claudeAiOauth", "accessToken"]);
        let refresh_token = get_path_string(&root, &["claudeAiOauth", "refreshToken"]);
        Ok((access_token, refresh_token))
    }

    #[derive(Clone, Default)]
    struct ProcessRecorder {
        add_count: Arc<Mutex<usize>>,
        last_added_secret: Arc<Mutex<Option<String>>>,
    }

    impl ProcessRecorder {
        fn runner(&self) -> ProcessRunner {
            let recorder = self.clone();
            Arc::new(move |executable, arguments| recorder.run(executable, arguments))
        }

        fn run(&self, executable: &str, arguments: &[String]) -> ProcessExecutionResult {
            if !executable.ends_with("security") {
                return ProcessExecutionResult {
                    status: 1,
                    stdout: String::new(),
                    stderr: "unexpected executable".to_string(),
                };
            }

            let Some(command) = arguments.first() else {
                return ProcessExecutionResult {
                    status: 1,
                    stdout: String::new(),
                    stderr: "missing command".to_string(),
                };
            };

            if command == "find-generic-password" && arguments.iter().any(|arg| arg == "-g") {
                return ProcessExecutionResult {
                    status: 0,
                    stdout: String::new(),
                    stderr: "keychain: \"acct\"<blob>=\"tester\"\n".to_string(),
                };
            }
            if command == "find-generic-password" && arguments.iter().any(|arg| arg == "-w") {
                return ProcessExecutionResult {
                    status: 1,
                    stdout: String::new(),
                    stderr: "not found".to_string(),
                };
            }
            if command == "add-generic-password" {
                if let Ok(mut count) = self.add_count.lock() {
                    *count += 1;
                }
                if let Some(index) = arguments.iter().position(|arg| arg == "-w") {
                    if let Some(value) = arguments.get(index + 1) {
                        if let Ok(mut secret) = self.last_added_secret.lock() {
                            *secret = Some(value.clone());
                        }
                    }
                }
                return ProcessExecutionResult {
                    status: 0,
                    stdout: String::new(),
                    stderr: String::new(),
                };
            }

            ProcessExecutionResult {
                status: 0,
                stdout: String::new(),
                stderr: String::new(),
            }
        }

        fn add_count(&self) -> usize {
            *self.add_count.lock().expect("add count")
        }

        fn last_added_secret(&self) -> Option<String> {
            self.last_added_secret.lock().expect("secret").clone()
        }
    }

    #[test]
    fn parse_supports_check_usage_command() {
        let command = CliCommand::parse(&["check-usage".to_string()])
            .expect("check-usage command should parse");
        assert!(matches!(
            command,
            CliCommand::CheckUsage {
                account_id: None,
                json: false
            }
        ));
    }

    #[test]
    fn parse_supports_check_usage_json_flag() {
        let command = CliCommand::parse(&["check-usage".to_string(), "--json".to_string()])
            .expect("check-usage --json should parse");
        assert!(matches!(
            command,
            CliCommand::CheckUsage {
                account_id: None,
                json: true
            }
        ));
    }

    #[test]
    fn parse_supports_check_usage_account_and_json() {
        let command = CliCommand::parse(&[
            "check-usage".to_string(),
            "--account".to_string(),
            "acct_test".to_string(),
            "--json".to_string(),
        ])
        .expect("check-usage --account --json should parse");
        match command {
            CliCommand::CheckUsage { account_id, json } => {
                assert_eq!(account_id.as_deref(), Some("acct_test"));
                assert!(json);
            }
            _ => panic!("expected CheckUsage"),
        }
    }

    #[test]
    fn recommendation_picks_lowest_usage() {
        let claude = CheckUsageInfo {
            name: "Claude".to_string(),
            available: true,
            error: false,
            five_hour_percent: Some(60.0),
            seven_day_percent: Some(20.0),
            five_hour_reset: None,
            seven_day_reset: None,
            model: None,
            plan: None,
            buckets: None,
        };
        let codex = CheckUsageInfo {
            name: "Codex".to_string(),
            available: true,
            error: false,
            five_hour_percent: Some(30.0),
            seven_day_percent: None,
            five_hour_reset: None,
            seven_day_reset: None,
            model: None,
            plan: None,
            buckets: None,
        };
        let (name, reason) = compute_check_usage_recommendation(&claude, Some(&codex), None, None);
        assert_eq!(name.as_deref(), Some("codex"));
        assert!(reason.contains("30%"));
    }

    #[test]
    fn recommendation_returns_none_when_no_data() {
        let claude = CheckUsageInfo::error_result("Claude");
        let (name, reason) = compute_check_usage_recommendation(&claude, None, None, None);
        assert!(name.is_none());
        assert_eq!(reason, "No usage data available");
    }

    #[test]
    fn normalize_to_iso_parses_rfc3339() {
        let result = normalize_to_iso("2026-02-12T10:00:00Z");
        assert!(result.is_some());
        assert!(result.unwrap().starts_with("2026-02-12T10:00:00"));
    }

    #[test]
    fn extract_url_origin_works() {
        assert_eq!(
            extract_url_origin("https://api.z.ai/v1/messages"),
            Some("https://api.z.ai".to_string())
        );
        assert_eq!(
            extract_url_origin("https://bigmodel.cn"),
            Some("https://bigmodel.cn".to_string())
        );
    }

    #[test]
    fn check_usage_json_output_matches_swift_decodable() {
        let output = CheckUsageOutput {
            claude: CheckUsageInfo {
                name: "Claude".to_string(),
                available: true,
                error: false,
                five_hour_percent: Some(42.0),
                seven_day_percent: Some(15.0),
                five_hour_reset: Some("2026-02-12T10:00:00.000Z".to_string()),
                seven_day_reset: Some("2026-02-15T00:00:00.000Z".to_string()),
                model: None,
                plan: None,
                buckets: None,
            },
            codex: None,
            gemini: None,
            zai: None,
            recommendation: Some("claude".to_string()),
            recommendation_reason: "Lowest usage (42% used)".to_string(),
        };
        let json = serde_json::to_string_pretty(&output).expect("serialize");
        let parsed: Value = serde_json::from_str(&json).expect("parse");
        assert_eq!(parsed.get("claude").unwrap().get("name").unwrap(), "Claude");
        assert_eq!(
            parsed.get("claude").unwrap().get("available").unwrap(),
            true
        );
        assert_eq!(
            parsed
                .get("claude")
                .unwrap()
                .get("fiveHourPercent")
                .unwrap(),
            42.0
        );
        assert!(parsed.get("codex").unwrap().is_null());
        assert_eq!(parsed.get("recommendation").unwrap(), "claude");
        assert_eq!(
            parsed.get("recommendationReason").unwrap(),
            "Lowest usage (42% used)"
        );
    }
}
