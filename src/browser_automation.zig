const std = @import("std");
const browser_runtime = @import("browser_runtime.zig");

pub const max_output_bytes: usize = 2 * 1024 * 1024;
pub const max_input_bytes: usize = 512 * 1024;
pub const max_timeout_seconds: u32 = 600;
pub const default_timeout_seconds: u32 = 90;
pub const max_download_bytes: usize = 10 * 1024 * 1024;
const max_error_excerpt_bytes: usize = 4096;

pub const ExecuteOptions = struct {
    browsers_path: []const u8,
    workspace_root: []const u8,
    session_dir: []const u8,
    allow_private_destinations: bool = false,
};

pub fn execute(
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
    options: ExecuteOptions,
) ![]u8 {
    if (arguments_json.len == 0 or arguments_json.len > max_input_bytes) {
        return error.InvalidToolArguments;
    }

    // Validate top-level JSON shape before passing data to Playwright.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidToolArguments,
    };

    if (root.get("session_id")) |session_id_value| {
        const session_id = switch (session_id_value) {
            .string => |value| value,
            else => return error.InvalidToolArguments,
        };
        if (!isValidSessionId(session_id)) return error.InvalidToolArguments;
    }

    if (root.get("session_dispose")) |session_dispose_value| {
        _ = switch (session_dispose_value) {
            .bool => {},
            else => return error.InvalidToolArguments,
        };
    }

    try ensureNpxAvailable(allocator);

    const playwright_package = try std.fmt.allocPrint(
        allocator,
        "playwright@{s}",
        .{browser_runtime.playwright_version},
    );
    defer allocator.free(playwright_package);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("PLAYWRIGHT_BROWSERS_PATH", options.browsers_path);
    try env_map.put("PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD", "1");
    try env_map.put("npm_config_loglevel", "silent");
    try env_map.put("npm_config_yes", "true");
    try env_map.put("ZOID_BROWSER_WORKSPACE_ROOT", options.workspace_root);
    try env_map.put("ZOID_BROWSER_SESSION_DIR", options.session_dir);
    try env_map.put("ZOID_BROWSER_MAX_DOWNLOAD_BYTES", "10485760");
    try env_map.put(
        "ZOID_BROWSER_ALLOW_PRIVATE_DESTINATIONS",
        if (options.allow_private_destinations) "1" else "0",
    );

    const argv = [_][]const u8{
        "npx",
        "--yes",
        "--quiet",
        "-p",
        playwright_package,
        "node",
        "-e",
        js_driver_source,
        arguments_json,
    };

    const command_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .env_map = &env_map,
        .max_output_bytes = max_output_bytes,
    });
    defer allocator.free(command_result.stdout);
    defer allocator.free(command_result.stderr);

    const payload = extractJsonPayload(command_result.stdout);
    if (payload) |value| {
        if (try isValidToolPayload(allocator, value)) {
            return allocator.dupe(u8, value);
        }
    }

    return buildFailureResult(
        allocator,
        command_result.term,
        command_result.stdout,
        command_result.stderr,
        payload != null,
    );
}

fn ensureNpxAvailable(allocator: std.mem.Allocator) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "npx", "--version" },
        .max_output_bytes = 16 * 1024,
    }) catch {
        return error.BrowserRuntimeNotFound;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |exit_code| {
            if (exit_code != 0) return error.BrowserRuntimeNotFound;
        },
        else => return error.BrowserRuntimeNotFound,
    }
}

fn extractJsonPayload(stdout_bytes: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, stdout_bytes, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (isJsonObject(trimmed)) return trimmed;

    var line_end = trimmed.len;
    while (line_end > 0) {
        const line_start = (std.mem.lastIndexOfScalar(u8, trimmed[0..line_end], '\n') orelse 0);
        const candidate = if (line_start == 0)
            trimmed[0..line_end]
        else
            trimmed[line_start + 1 .. line_end];
        const line = std.mem.trim(u8, candidate, " \t\r\n");
        if (line.len > 0 and isJsonObject(line)) return line;
        if (line_start == 0) break;
        line_end = line_start;
    }
    return null;
}

fn isValidToolPayload(allocator: std.mem.Allocator, payload: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return false;
    defer parsed.deinit();

    const payload_root = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    const tool_name = switch (payload_root.get("tool") orelse return false) {
        .string => |value| value,
        else => return false,
    };
    if (!std.mem.eql(u8, tool_name, "browser_automate")) return false;
    _ = switch (payload_root.get("ok") orelse return false) {
        .bool => {},
        else => return false,
    };
    return true;
}

fn buildFailureResult(
    allocator: std.mem.Allocator,
    term: std.process.Child.Term,
    stdout_bytes: []const u8,
    stderr_bytes: []const u8,
    payload_found: bool,
) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("{\"ok\":false,\"tool\":\"browser_automate\",\"error\":\"BrowserAutomationFailed\"");

    switch (term) {
        .Exited => |exit_code| {
            try writer.writeAll(",\"exit_code\":");
            try writer.print("{d}", .{exit_code});
        },
        else => {
            try writer.writeAll(",\"exit_code\":null");
        },
    }

    try writer.writeAll(",\"payload_found\":");
    try writer.writeAll(if (payload_found) "true" else "false");

    const stdout_excerpt = tailExcerpt(stdout_bytes, max_error_excerpt_bytes);
    const stderr_excerpt = tailExcerpt(stderr_bytes, max_error_excerpt_bytes);

    try writer.writeAll(",\"stdout_excerpt\":");
    try writeJsonString(allocator, writer, stdout_excerpt);
    try writer.writeAll(",\"stderr_excerpt\":");
    try writeJsonString(allocator, writer, stderr_excerpt);
    try writer.writeAll("}");

    return output.toOwnedSlice();
}

fn tailExcerpt(value: []const u8, max_bytes: usize) []const u8 {
    if (value.len <= max_bytes) return value;
    return value[value.len - max_bytes ..];
}

fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(escaped);
    try writer.writeAll(escaped);
}

fn isJsonObject(value: []const u8) bool {
    return value.len >= 2 and value[0] == '{' and value[value.len - 1] == '}';
}

fn isValidSessionId(session_id: []const u8) bool {
    if (session_id.len == 0 or session_id.len > 64) return false;
    for (session_id) |char| {
        if ((char >= 'a' and char <= 'z') or
            (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or
            char == '_' or
            char == '-')
        {
            continue;
        }
        return false;
    }
    return true;
}

const js_driver_source =
    \\const dns = require("node:dns").promises;
    \\const fs = require("node:fs/promises");
    \\const net = require("node:net");
    \\const path = require("node:path");
    \\
    \\function loadPlaywrightModule() {
    \\  try {
    \\    return require("playwright");
    \\  } catch (_) {
    \\    // Continue with PATH/.bin-based discovery.
    \\  }
    \\
    \\  const pathEnv = process.env.PATH || "";
    \\  const entries = pathEnv.split(path.delimiter).filter((entry) => entry.length > 0);
    \\  for (const entry of entries) {
    \\    const normalized = entry.replace(/[\\\/]+$/, "");
    \\    const baseName = path.basename(normalized);
    \\    if (baseName !== ".bin") continue;
    \\    const candidate = path.resolve(normalized, "..", "playwright");
    \\    try {
    \\      return require(candidate);
    \\    } catch (_) {
    \\      // Try next candidate.
    \\    }
    \\  }
    \\
    \\  throw new Error("Cannot find module 'playwright' in runtime or npx package context.");
    \\}
    \\
    \\const { chromium } = loadPlaywrightModule();
    \\
    \\const inputJson = process.argv[1];
    \\const allowPrivateDestinations = process.env.ZOID_BROWSER_ALLOW_PRIVATE_DESTINATIONS === "1";
    \\const workspaceRoot = process.env.ZOID_BROWSER_WORKSPACE_ROOT || "";
    \\const sessionDir = process.env.ZOID_BROWSER_SESSION_DIR || "";
    \\const maxDownloadBytes = Number(process.env.ZOID_BROWSER_MAX_DOWNLOAD_BYTES || "10485760");
    \\
    \\function asInt(value, fallback, min, max) {
    \\  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
    \\  const normalized = Math.floor(value);
    \\  if (normalized < min) return min;
    \\  if (normalized > max) return max;
    \\  return normalized;
    \\}
    \\
    \\function trimTo(text, maxChars) {
    \\  if (typeof text !== "string") return "";
    \\  if (text.length <= maxChars) return text;
    \\  return text.slice(0, maxChars);
    \\}
    \\
    \\function toJsonSafe(value) {
    \\  if (value === null || value === undefined) return null;
    \\  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") return value;
    \\  try {
    \\    return JSON.parse(JSON.stringify(value));
    \\  } catch {
    \\    return String(value);
    \\  }
    \\}
    \\
    \\function isBlockedIpv4Address(address) {
    \\  const parts = address.split(".");
    \\  if (parts.length !== 4) return true;
    \\  const values = parts.map((part) => Number(part));
    \\  if (values.some((value) => !Number.isInteger(value) || value < 0 || value > 255)) return true;
    \\  const a = values[0];
    \\  const b = values[1];
    \\  if (a === 0 || a === 10 || a === 127) return true;
    \\  if (a === 169 && b === 254) return true;
    \\  if (a === 172 && b >= 16 && b <= 31) return true;
    \\  if (a === 192 && b === 168) return true;
    \\  return false;
    \\}
    \\
    \\function isBlockedIpv6Address(address) {
    \\  const lower = address.toLowerCase();
    \\  if (lower === "::" || lower === "::1") return true;
    \\  if (lower.startsWith("fc") || lower.startsWith("fd")) return true;
    \\  if (lower.startsWith("fe8") || lower.startsWith("fe9") || lower.startsWith("fea") || lower.startsWith("feb")) return true;
    \\  if (lower.startsWith("::ffff:")) {
    \\    const mapped = lower.slice("::ffff:".length);
    \\    return isBlockedIpv4Address(mapped);
    \\  }
    \\  return false;
    \\}
    \\
    \\function isBlockedHostName(hostname) {
    \\  const normalized = hostname.replace(/[.]+$/, "").toLowerCase();
    \\  if (!normalized) return true;
    \\  if (normalized === "localhost") return true;
    \\  if (normalized.endsWith(".localhost")) return true;
    \\  return false;
    \\}
    \\
    \\async function buildHostBlocker() {
    \\  const cache = new Map();
    \\  return async function isHostBlocked(hostname) {
    \\    const normalized = hostname.replace(/[.]+$/, "").toLowerCase();
    \\    if (cache.has(normalized)) return cache.get(normalized);
    \\    if (isBlockedHostName(normalized)) {
    \\      cache.set(normalized, true);
    \\      return true;
    \\    }
    \\    const ipType = net.isIP(normalized);
    \\    if (ipType === 4) {
    \\      const blocked = isBlockedIpv4Address(normalized);
    \\      cache.set(normalized, blocked);
    \\      return blocked;
    \\    }
    \\    if (ipType === 6) {
    \\      const blocked = isBlockedIpv6Address(normalized);
    \\      cache.set(normalized, blocked);
    \\      return blocked;
    \\    }
    \\    let blocked = true;
    \\    try {
    \\      const addresses = await dns.lookup(normalized, { all: true, verbatim: true });
    \\      if (Array.isArray(addresses) && addresses.length > 0) {
    \\        blocked = addresses.some((entry) => {
    \\          if (!entry || typeof entry.address !== "string") return true;
    \\          return net.isIP(entry.address) === 4
    \\            ? isBlockedIpv4Address(entry.address)
    \\            : isBlockedIpv6Address(entry.address);
    \\        });
    \\      }
    \\    } catch {
    \\      blocked = true;
    \\    }
    \\    cache.set(normalized, blocked);
    \\    return blocked;
    \\  };
    \\}
    \\
    \\async function isBlockedUrl(rawUrl, isHostBlocked) {
    \\  let parsed;
    \\  try {
    \\    parsed = new URL(rawUrl);
    \\  } catch {
    \\    return true;
    \\  }
    \\  const protocol = parsed.protocol.toLowerCase();
    \\  if (protocol !== "http:" && protocol !== "https:") return true;
    \\  return await isHostBlocked(parsed.hostname);
    \\}
    \\
    \\function requireString(action, fieldName) {
    \\  const value = action[fieldName];
    \\  if (typeof value !== "string" || value.length === 0) {
    \\    throw new Error(`Action ${action.action}: missing string field '${fieldName}'`);
    \\  }
    \\  return value;
    \\}
    \\
    \\function optionalTimeout(action, fallback) {
    \\  if (action.timeout_ms === undefined) return fallback;
    \\  return asInt(action.timeout_ms, fallback, 100, 600000);
    \\}
    \\
    \\function validateSessionId(value) {
    \\  return typeof value === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(value);
    \\}
    \\
    \\function normalizedWorkspaceRoot() {
    \\  if (typeof workspaceRoot !== "string" || workspaceRoot.length === 0) {
    \\    throw new Error("Workspace root is not configured.");
    \\  }
    \\  return path.resolve(workspaceRoot);
    \\}
    \\
    \\function toWorkspacePath(absPath, rootPath) {
    \\  const rel = path.relative(rootPath, absPath);
    \\  if (!rel || rel === ".") return "/";
    \\  return "/" + rel.split(path.sep).join("/");
    \\}
    \\
    \\function ensureInsideWorkspace(absPath, rootPath) {
    \\  if (absPath === rootPath) return true;
    \\  const prefixed = rootPath.endsWith(path.sep) ? rootPath : rootPath + path.sep;
    \\  return absPath.startsWith(prefixed);
    \\}
    \\
    \\function resolveWorkspacePath(inputPath, rootPath) {
    \\  if (typeof inputPath !== "string" || inputPath.length === 0) {
    \\    throw new Error("Path must be a non-empty string.");
    \\  }
    \\  let resolved;
    \\  if (inputPath.startsWith("/")) {
    \\    resolved = path.resolve(rootPath, inputPath.slice(1));
    \\  } else if (path.isAbsolute(inputPath)) {
    \\    resolved = path.resolve(inputPath);
    \\  } else {
    \\    resolved = path.resolve(rootPath, inputPath);
    \\  }
    \\  if (!ensureInsideWorkspace(resolved, rootPath)) {
    \\    throw new Error(`Path outside workspace: ${inputPath}`);
    \\  }
    \\  return resolved;
    \\}
    \\
    \\async function readSessionState(sessionId) {
    \\  if (!validateSessionId(sessionId)) throw new Error("Invalid session_id.");
    \\  const sessionPath = path.join(sessionDir, `${sessionId}.json`);
    \\  try {
    \\    const content = await fs.readFile(sessionPath, "utf8");
    \\    const parsed = JSON.parse(content);
    \\    if (typeof parsed !== "object" || parsed === null) return null;
    \\    return parsed;
    \\  } catch {
    \\    return null;
    \\  }
    \\}
    \\
    \\async function writeSessionState(sessionId, state) {
    \\  if (!validateSessionId(sessionId)) throw new Error("Invalid session_id.");
    \\  await fs.mkdir(sessionDir, { recursive: true });
    \\  const sessionPath = path.join(sessionDir, `${sessionId}.json`);
    \\  const tempPath = `${sessionPath}.tmp`;
    \\  await fs.writeFile(tempPath, JSON.stringify(state), "utf8");
    \\  await fs.rename(tempPath, sessionPath);
    \\}
    \\
    \\async function deleteSessionState(sessionId) {
    \\  if (!validateSessionId(sessionId)) throw new Error("Invalid session_id.");
    \\  const sessionPath = path.join(sessionDir, `${sessionId}.json`);
    \\  await fs.unlink(sessionPath).catch(() => {});
    \\}
    \\
    \\function normalizeActionFilePaths(action) {
    \\  if (Array.isArray(action.path)) return action.path;
    \\  if (Array.isArray(action.paths)) return action.paths;
    \\  if (typeof action.path === "string") return [action.path];
    \\  if (typeof action.paths === "string") return [action.paths];
    \\  return [];
    \\}
    \\
    \\function validateHeaderMap(headers) {
    \\  if (headers === undefined) return;
    \\  if (typeof headers !== "object" || headers === null || Array.isArray(headers)) {
    \\    throw new Error("headers must be an object");
    \\  }
    \\  for (const [name, value] of Object.entries(headers)) {
    \\    if (typeof value !== "string") throw new Error("headers values must be strings");
    \\    if (!/^[!#$%&'*+\-.^_`|~A-Za-z0-9]+$/.test(name)) throw new Error("invalid header name");
    \\    const lowered = name.toLowerCase();
    \\    if (lowered === "host" || lowered === "content-length" || lowered === "transfer-encoding") {
    \\      throw new Error(`header not allowed: ${name}`);
    \\    }
    \\  }
    \\}
    \\
    \\async function run() {
    \\  const rootPath = normalizedWorkspaceRoot();
    \\  const input = JSON.parse(inputJson);
    \\  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    \\    throw new Error("Input must be a JSON object.");
    \\  }
    \\
    \\  const timeoutSeconds = asInt(input.timeout_seconds, 90, 1, 600);
    \\  const timeoutMs = timeoutSeconds * 1000;
    \\  const actionTimeoutMs = asInt(input.action_timeout_ms, 30000, 100, timeoutMs);
    \\  const maxExtractItems = asInt(input.max_extract_items, 100, 1, 500);
    \\  const maxTextChars = asInt(input.max_text_chars, 20000, 256, 200000);
    \\  const maxHtmlChars = asInt(input.max_html_chars, 50000, 256, 400000);
    \\  const continueOnError = input.continue_on_error === true;
    \\  const maxActions = asInt(input.max_actions, 200, 1, 500);
    \\
    \\  const hasSession = validateSessionId(input.session_id);
    \\  const sessionId = hasSession ? input.session_id : null;
    \\  const disposeSession = input.session_dispose === true;
    \\  const loadedSession = sessionId ? await readSessionState(sessionId) : null;
    \\
    \\  const viewport = {
    \\    width: asInt(input.viewport && input.viewport.width, loadedSession && loadedSession.viewport && loadedSession.viewport.width ? loadedSession.viewport.width : 1280, 320, 4096),
    \\    height: asInt(input.viewport && input.viewport.height, loadedSession && loadedSession.viewport && loadedSession.viewport.height ? loadedSession.viewport.height : 900, 320, 4096),
    \\  };
    \\
    \\  const userAgent = typeof input.user_agent === "string"
    \\    ? input.user_agent
    \\    : (loadedSession && typeof loadedSession.user_agent === "string" ? loadedSession.user_agent : undefined);
    \\
    \\  const browser = await chromium.launch({ headless: true });
    \\  let context = null;
    \\  let page = null;
    \\  const isHostBlocked = await buildHostBlocker();
    \\
    \\  const result = {
    \\    ok: true,
    \\    tool: "browser_automate",
    \\    actions: [],
    \\    extracts: [],
    \\    final_url: null,
    \\    title: null,
    \\    session_id: sessionId,
    \\    session_restored: loadedSession != null,
    \\    session_saved: false,
    \\    session_disposed: false,
    \\  };
    \\
    \\  try {
    \\    const contextOptions = {
    \\      viewport,
    \\      userAgent,
    \\    };
    \\    if (loadedSession && loadedSession.storage_state) {
    \\      contextOptions.storageState = loadedSession.storage_state;
    \\    }
    \\
    \\    context = await browser.newContext(contextOptions);
    \\    page = await context.newPage();
    \\    page.setDefaultTimeout(actionTimeoutMs);
    \\    context.setDefaultTimeout(actionTimeoutMs);
    \\
    \\    if (!allowPrivateDestinations) {
    \\      await context.route("**/*", async (route) => {
    \\        const requestUrl = route.request().url();
    \\        if (await isBlockedUrl(requestUrl, isHostBlocked)) {
    \\          await route.abort();
    \\          return;
    \\        }
    \\        await route.continue();
    \\      });
    \\    }
    \\
    \\    async function executeAction(action, index) {
    \\      if (typeof action !== "object" || action === null || Array.isArray(action)) {
    \\        throw new Error(`Action ${index} must be an object.`);
    \\      }
    \\      if (typeof action.action !== "string" || action.action.length === 0) {
    \\        throw new Error(`Action ${index} is missing 'action'.`);
    \\      }
    \\      const actionName = action.action;
    \\      const timeout = optionalTimeout(action, actionTimeoutMs);
    \\      const actionRecord = { index, action: actionName, ok: true };
    \\
    \\      if (actionName === "goto" || actionName === "open") {
    \\        const url = requireString(action, "url");
    \\        if (!allowPrivateDestinations && (await isBlockedUrl(url, isHostBlocked))) {
    \\          throw new Error(`Blocked destination: ${url}`);
    \\        }
    \\        await page.goto(url, { timeout, waitUntil: typeof action.wait_until === "string" ? action.wait_until : "domcontentloaded" });
    \\        actionRecord.url = page.url();
    \\      } else if (actionName === "click") {
    \\        const selector = requireString(action, "selector");
    \\        await page.click(selector, { timeout });
    \\        actionRecord.selector = selector;
    \\      } else if (actionName === "type") {
    \\        const selector = requireString(action, "selector");
    \\        const text = requireString(action, "text");
    \\        if (action.clear === true) {
    \\          await page.fill(selector, text, { timeout });
    \\        } else {
    \\          await page.click(selector, { timeout });
    \\          await page.type(selector, text, {
    \\            delay: asInt(action.delay_ms, 0, 0, 1000),
    \\            timeout,
    \\          });
    \\        }
    \\        actionRecord.selector = selector;
    \\        actionRecord.chars = text.length;
    \\      } else if (actionName === "fill") {
    \\        const selector = requireString(action, "selector");
    \\        const text = requireString(action, "text");
    \\        await page.fill(selector, text, { timeout });
    \\        actionRecord.selector = selector;
    \\        actionRecord.chars = text.length;
    \\      } else if (actionName === "press") {
    \\        const key = requireString(action, "key");
    \\        if (typeof action.selector === "string" && action.selector.length > 0) {
    \\          await page.press(action.selector, key, { timeout });
    \\          actionRecord.selector = action.selector;
    \\        } else {
    \\          await page.keyboard.press(key);
    \\        }
    \\        actionRecord.key = key;
    \\      } else if (actionName === "select_option") {
    \\        const selector = requireString(action, "selector");
    \\        const value = action.value;
    \\        if (typeof value !== "string" && !Array.isArray(value)) {
    \\          throw new Error("Action select_option requires 'value' (string or array of strings).");
    \\        }
    \\        await page.selectOption(selector, value, { timeout });
    \\        actionRecord.selector = selector;
    \\      } else if (actionName === "check") {
    \\        const selector = requireString(action, "selector");
    \\        await page.check(selector, { timeout });
    \\        actionRecord.selector = selector;
    \\      } else if (actionName === "uncheck") {
    \\        const selector = requireString(action, "selector");
    \\        await page.uncheck(selector, { timeout });
    \\        actionRecord.selector = selector;
    \\      } else if (actionName === "wait_for_selector") {
    \\        const selector = requireString(action, "selector");
    \\        await page.waitForSelector(selector, {
    \\          timeout,
    \\          state: typeof action.state === "string" ? action.state : "visible",
    \\        });
    \\        actionRecord.selector = selector;
    \\      } else if (actionName === "wait_for_url") {
    \\        const value = requireString(action, "value");
    \\        if (action.match === "exact") {
    \\          await page.waitForURL((url) => url.toString() === value, { timeout });
    \\        } else if (action.match === "regex") {
    \\          const pattern = new RegExp(value);
    \\          await page.waitForURL((url) => pattern.test(url.toString()), { timeout });
    \\        } else {
    \\          await page.waitForURL((url) => url.toString().includes(value), { timeout });
    \\        }
    \\        actionRecord.value = value;
    \\      } else if (actionName === "wait_for_timeout") {
    \\        const waitMs = asInt(action.ms, 250, 1, timeoutMs);
    \\        await page.waitForTimeout(waitMs);
    \\        actionRecord.ms = waitMs;
    \\      } else if (actionName === "submit") {
    \\        const selector = typeof action.selector === "string" && action.selector.length > 0 ? action.selector : null;
    \\        if (selector) {
    \\          await page.$eval(selector, (element) => {
    \\            if (!(element instanceof HTMLFormElement)) {
    \\              throw new Error("selector does not point to a form element");
    \\            }
    \\            element.submit();
    \\          });
    \\        } else {
    \\          await page.keyboard.press("Enter");
    \\        }
    \\        if (action.wait_for_navigation !== false) {
    \\          await page.waitForLoadState("domcontentloaded", { timeout });
    \\        }
    \\        actionRecord.selector = selector;
    \\      } else if (actionName === "extract_text") {
    \\        const selector = requireString(action, "selector");
    \\        const text = await page.textContent(selector, { timeout });
    \\        const value = trimTo(text || "", maxTextChars);
    \\        result.extracts.push({
    \\          kind: "text",
    \\          name: typeof action.name === "string" ? action.name : selector,
    \\          selector,
    \\          value,
    \\        });
    \\        actionRecord.selector = selector;
    \\        actionRecord.chars = value.length;
    \\      } else if (actionName === "extract_html") {
    \\        const selector = requireString(action, "selector");
    \\        const html = await page.$eval(selector, (element) => element.outerHTML);
    \\        const value = trimTo(html || "", maxHtmlChars);
    \\        result.extracts.push({
    \\          kind: "html",
    \\          name: typeof action.name === "string" ? action.name : selector,
    \\          selector,
    \\          value,
    \\        });
    \\        actionRecord.selector = selector;
    \\        actionRecord.chars = value.length;
    \\      } else if (actionName === "extract_links") {
    \\        const selector = typeof action.selector === "string" && action.selector.length > 0 ? action.selector : "a";
    \\        const limit = asInt(action.max_links, maxExtractItems, 1, maxExtractItems);
    \\        const links = await page.$$eval(selector, (elements, maxItemsInner) => {
    \\          return elements.slice(0, maxItemsInner).map((element) => {
    \\            const href = element.href || element.getAttribute("href") || "";
    \\            const text = (element.textContent || "").trim();
    \\            return { href, text };
    \\          });
    \\        }, limit);
    \\        result.extracts.push({
    \\          kind: "links",
    \\          name: typeof action.name === "string" ? action.name : selector,
    \\          selector,
    \\          items: links,
    \\        });
    \\        actionRecord.selector = selector;
    \\        actionRecord.items = links.length;
    \\      } else if (actionName === "extract_page_text") {
    \\        const text = await page.$eval("body", (element) => element.innerText || "");
    \\        const value = trimTo(text || "", maxTextChars);
    \\        result.extracts.push({
    \\          kind: "page_text",
    \\          name: typeof action.name === "string" ? action.name : "page_text",
    \\          value,
    \\        });
    \\        actionRecord.chars = value.length;
    \\      } else if (actionName === "evaluate") {
    \\        const script = requireString(action, "script");
    \\        const evalResult = await page.evaluate(
    \\          ({ source, arg }) => {
    \\            const fn = new Function("arg", source);
    \\            return fn(arg);
    \\          },
    \\          { source: script, arg: action.arg === undefined ? null : action.arg },
    \\        );
    \\        result.extracts.push({
    \\          kind: "evaluate",
    \\          name: typeof action.name === "string" ? action.name : "evaluate",
    \\          value: toJsonSafe(evalResult),
    \\        });
    \\      } else if (actionName === "screenshot") {
    \\        const imageType = action.type === "jpeg" ? "jpeg" : "png";
    \\        const screenshotOptions = {
    \\          type: imageType,
    \\          fullPage: action.full_page === true,
    \\          timeout,
    \\        };
    \\        if (imageType === "jpeg" && typeof action.quality === "number") {
    \\          screenshotOptions.quality = asInt(action.quality, 80, 1, 100);
    \\        }
    \\
    \\        const selector = typeof action.selector === "string" && action.selector.length > 0 ? action.selector : null;
    \\        let target = page;
    \\        if (selector) {
    \\          const element = await page.$(selector);
    \\          if (!element) throw new Error(`No element found for selector: ${selector}`);
    \\          target = element;
    \\          screenshotOptions.fullPage = undefined;
    \\        }
    \\
    \\        const destinationPath = typeof action.path === "string" && action.path.length > 0
    \\          ? resolveWorkspacePath(action.path, rootPath)
    \\          : null;
    \\
    \\        if (destinationPath) {
    \\          await fs.mkdir(path.dirname(destinationPath), { recursive: true });
    \\          await target.screenshot({ ...screenshotOptions, path: destinationPath });
    \\          const stat = await fs.stat(destinationPath);
    \\          actionRecord.path = toWorkspacePath(destinationPath, rootPath);
    \\          actionRecord.bytes = stat.size;
    \\        } else {
    \\          const buffer = await target.screenshot(screenshotOptions);
    \\          const base64 = Buffer.from(buffer).toString("base64");
    \\          const maxBase64Chars = asInt(action.max_base64_chars, 200000, 1024, 500000);
    \\          const truncated = base64.length > maxBase64Chars;
    \\          const value = truncated ? base64.slice(0, maxBase64Chars) : base64;
    \\          result.extracts.push({
    \\            kind: "screenshot_base64",
    \\            name: typeof action.name === "string" ? action.name : "screenshot",
    \\            mime: imageType === "jpeg" ? "image/jpeg" : "image/png",
    \\            value,
    \\            truncated,
    \\          });
    \\          actionRecord.chars = value.length;
    \\          actionRecord.truncated = truncated;
    \\        }
    \\        if (selector && target && typeof target.dispose === "function") {
    \\          await target.dispose();
    \\        }
    \\      } else if (actionName === "download") {
    \\        const url = requireString(action, "url");
    \\        if (!allowPrivateDestinations && (await isBlockedUrl(url, isHostBlocked))) {
    \\          throw new Error(`Blocked destination: ${url}`);
    \\        }
    \\        const saveAs = resolveWorkspacePath(requireString(action, "save_as"), rootPath);
    \\        const method = typeof action.method === "string" ? action.method.toUpperCase() : "GET";
    \\        if (method !== "GET" && method !== "POST" && method !== "PUT" && method !== "DELETE") {
    \\          throw new Error(`Unsupported download method: ${method}`);
    \\        }
    \\        validateHeaderMap(action.headers);
    \\        const response = await context.request.fetch(url, {
    \\          method,
    \\          data: typeof action.body === "string" ? action.body : undefined,
    \\          headers: action.headers,
    \\          timeout,
    \\        });
    \\        const payload = Buffer.from(await response.body());
    \\        if (payload.length > maxDownloadBytes) {
    \\          throw new Error(`Downloaded payload too large (${payload.length} bytes)`);
    \\        }
    \\        await fs.mkdir(path.dirname(saveAs), { recursive: true });
    \\        await fs.writeFile(saveAs, payload);
    \\        actionRecord.status = response.status();
    \\        actionRecord.bytes = payload.length;
    \\        actionRecord.save_as = toWorkspacePath(saveAs, rootPath);
    \\      } else if (actionName === "upload") {
    \\        const selector = requireString(action, "selector");
    \\        const fileInputs = normalizeActionFilePaths(action);
    \\        if (fileInputs.length === 0) throw new Error("upload requires path or paths");
    \\        const files = [];
    \\        for (const item of fileInputs) {
    \\          const absPath = resolveWorkspacePath(item, rootPath);
    \\          const stat = await fs.stat(absPath);
    \\          if (!stat.isFile()) throw new Error(`upload source is not a file: ${item}`);
    \\          files.push(absPath);
    \\        }
    \\        await page.setInputFiles(selector, files);
    \\        actionRecord.selector = selector;
    \\        actionRecord.paths = files.map((filePath) => toWorkspacePath(filePath, rootPath));
    \\      } else {
    \\        throw new Error(`Unsupported action: ${actionName}`);
    \\      }
    \\
    \\      actionRecord.current_url = page.url();
    \\      result.actions.push(actionRecord);
    \\    }
    \\
    \\    if (typeof input.start_url === "string" && input.start_url.length > 0) {
    \\      if (!allowPrivateDestinations && (await isBlockedUrl(input.start_url, isHostBlocked))) {
    \\        throw new Error(`Blocked destination: ${input.start_url}`);
    \\      }
    \\      await page.goto(input.start_url, { timeout: actionTimeoutMs, waitUntil: "domcontentloaded" });
    \\    } else if (loadedSession && typeof loadedSession.last_url === "string" && loadedSession.last_url.length > 0) {
    \\      await page.goto(loadedSession.last_url, { timeout: actionTimeoutMs, waitUntil: "domcontentloaded" });
    \\    }
    \\
    \\    const actions = Array.isArray(input.actions) ? input.actions : [];
    \\    if (actions.length > maxActions) {
    \\      throw new Error(`Too many actions (${actions.length}). Max is ${maxActions}.`);
    \\    }
    \\
    \\    for (let index = 0; index < actions.length; index += 1) {
    \\      const action = actions[index];
    \\      try {
    \\        await executeAction(action, index);
    \\      } catch (error) {
    \\        const message = error && error.message ? error.message : String(error);
    \\        result.actions.push({
    \\          index,
    \\          action: typeof action === "object" && action !== null ? action.action : "unknown",
    \\          ok: false,
    \\          error: message,
    \\          current_url: page.url(),
    \\        });
    \\        if (!continueOnError) {
    \\          result.ok = false;
    \\          result.error = message;
    \\          break;
    \\        }
    \\      }
    \\    }
    \\
    \\    result.final_url = page.url();
    \\    result.title = await page.title();
    \\
    \\    if (sessionId) {
    \\      if (disposeSession) {
    \\        await deleteSessionState(sessionId);
    \\        result.session_disposed = true;
    \\        result.session_saved = false;
    \\      } else {
    \\        const storageState = await context.storageState();
    \\        await writeSessionState(sessionId, {
    \\          session_id: sessionId,
    \\          last_url: page.url(),
    \\          user_agent: userAgent || null,
    \\          viewport,
    \\          storage_state: storageState,
    \\          updated_at_epoch: Math.floor(Date.now() / 1000),
    \\        });
    \\        result.session_saved = true;
    \\      }
    \\    }
    \\
    \\    return result;
    \\  } finally {
    \\    if (context) {
    \\      await context.close().catch(() => {});
    \\    }
    \\    await browser.close().catch(() => {});
    \\  }
    \\}
    \\
    \\(async () => {
    \\  try {
    \\    const result = await run();
    \\    process.stdout.write(JSON.stringify(result));
    \\  } catch (error) {
    \\    const message = error && error.message ? error.message : String(error);
    \\    process.stdout.write(JSON.stringify({
    \\      ok: false,
    \\      tool: "browser_automate",
    \\      error: message,
    \\    }));
    \\  }
    \\})();
;

test "extractJsonPayload accepts full JSON and last line JSON" {
    try std.testing.expectEqualStrings(
        "{\"ok\":true}",
        extractJsonPayload("{\"ok\":true}\n").?,
    );
    try std.testing.expectEqualStrings(
        "{\"ok\":false}",
        extractJsonPayload("warn\n{\"ok\":false}\n").?,
    );
    try std.testing.expect(extractJsonPayload("warn only\n") == null);
}

test "isValidToolPayload validates browser tool envelope" {
    try std.testing.expect(try isValidToolPayload(
        std.testing.allocator,
        "{\"ok\":true,\"tool\":\"browser_automate\"}",
    ));
    try std.testing.expect(!(try isValidToolPayload(
        std.testing.allocator,
        "{\"ok\":true,\"tool\":\"http_get\"}",
    )));
    try std.testing.expect(!(try isValidToolPayload(
        std.testing.allocator,
        "{\"ok\":1,\"tool\":\"browser_automate\"}",
    )));
}

test "tailExcerpt returns entire input or clipped tail" {
    try std.testing.expectEqualStrings("abc", tailExcerpt("abc", 10));
    try std.testing.expectEqualStrings("def", tailExcerpt("abcdef", 3));
}

test "isValidSessionId allows only safe characters" {
    try std.testing.expect(isValidSessionId("session_1"));
    try std.testing.expect(isValidSessionId("abc-XYZ-123"));
    try std.testing.expect(!isValidSessionId(""));
    try std.testing.expect(!isValidSessionId("space id"));
    try std.testing.expect(!isValidSessionId("../../etc"));
}
