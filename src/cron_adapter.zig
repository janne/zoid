const std = @import("std");
const cron = @import("cron");
const c = @cImport({
    @cInclude("time.h");
});

pub const CronError = error{
    InvalidExpression,
    InvalidField,
    InvalidValue,
    InvalidRange,
    InvalidStep,
    TimeOutOfRange,
    TimeConversionFailed,
};

pub const CronSchedule = struct {
    minutes: [60]bool,
    hours: [24]bool,
    days_of_month: [32]bool,
    months: [13]bool,
    days_of_week: [7]bool,
    day_of_month_any: bool,
    day_of_week_any: bool,

    fn matchesEpochLocal(self: *const CronSchedule, epoch_seconds: i64) CronError!bool {
        const raw: c.time_t = std.math.cast(c.time_t, epoch_seconds) orelse return error.TimeOutOfRange;
        var raw_copy = raw;
        var tm_value: c.struct_tm = undefined;
        if (c.localtime_r(&raw_copy, &tm_value) == null) return error.TimeConversionFailed;

        const minute_index: usize = std.math.cast(usize, tm_value.tm_min) orelse return error.TimeConversionFailed;
        const hour_index: usize = std.math.cast(usize, tm_value.tm_hour) orelse return error.TimeConversionFailed;
        const day_of_month_index: usize = std.math.cast(usize, tm_value.tm_mday) orelse return error.TimeConversionFailed;

        const month_one_based = tm_value.tm_mon + 1;
        const month_index: usize = std.math.cast(usize, month_one_based) orelse return error.TimeConversionFailed;
        const day_of_week_index: usize = std.math.cast(usize, tm_value.tm_wday) orelse return error.TimeConversionFailed;

        if (!self.minutes[minute_index]) return false;
        if (!self.hours[hour_index]) return false;
        if (!self.months[month_index]) return false;

        const dom_match = self.days_of_month[day_of_month_index];
        const dow_match = self.days_of_week[day_of_week_index];
        const day_matches = if (self.day_of_month_any and self.day_of_week_any)
            true
        else if (self.day_of_month_any)
            dow_match
        else if (self.day_of_week_any)
            dom_match
        else
            dom_match or dow_match;

        return day_matches;
    }
};

pub fn parseCronExpression(expression: []const u8) CronError!CronSchedule {
    var external_cron = cron.Cron.init();
    external_cron.parse(expression) catch return error.InvalidExpression;

    var schedule: CronSchedule = .{
        .minutes = [_]bool{false} ** 60,
        .hours = [_]bool{false} ** 24,
        .days_of_month = [_]bool{false} ** 32,
        .months = [_]bool{false} ** 13,
        .days_of_week = [_]bool{false} ** 7,
        .day_of_month_any = false,
        .day_of_week_any = false,
    };

    var fields: [5][]const u8 = undefined;
    var field_count: usize = 0;
    var field_iter = std.mem.tokenizeAny(u8, expression, " \t\r\n");
    while (field_iter.next()) |field| {
        if (field_count >= fields.len) return error.InvalidExpression;
        fields[field_count] = field;
        field_count += 1;
    }
    if (field_count != fields.len) return error.InvalidExpression;

    try parseField(fields[0], &schedule.minutes, 0, 59, false);
    try parseField(fields[1], &schedule.hours, 0, 23, false);
    try parseField(fields[2], &schedule.days_of_month, 1, 31, false);
    try parseField(fields[3], &schedule.months, 1, 12, false);
    try parseField(fields[4], &schedule.days_of_week, 0, 6, true);

    schedule.day_of_month_any = std.mem.eql(u8, fields[2], "*");
    schedule.day_of_week_any = std.mem.eql(u8, fields[4], "*");

    return schedule;
}

pub fn nextRunAt(expression: []const u8, after_epoch_seconds: i64) CronError!?i64 {
    const schedule = try parseCronExpression(expression);

    const rounded = @divFloor(after_epoch_seconds, 60) * 60;
    var candidate = rounded + 60;

    const max_minutes_to_scan: usize = 10 * 366 * 24 * 60;
    var scanned: usize = 0;
    while (scanned < max_minutes_to_scan) : (scanned += 1) {
        if (try schedule.matchesEpochLocal(candidate)) return candidate;
        candidate += 60;
    }

    return null;
}

fn parseField(
    field_expression: []const u8,
    field: []bool,
    min_value: u8,
    max_value: u8,
    map_seven_to_zero: bool,
) CronError!void {
    if (field_expression.len == 0) return error.InvalidField;

    if (std.mem.eql(u8, field_expression, "*")) {
        var value = min_value;
        while (value <= max_value) : (value += 1) {
            field[value] = true;
        }
        return;
    }

    var part_iter = std.mem.tokenizeScalar(u8, field_expression, ',');
    var had_part = false;
    while (part_iter.next()) |part| {
        had_part = true;
        try applyFieldPart(part, field, min_value, max_value, map_seven_to_zero);
    }

    if (!had_part) return error.InvalidField;
}

fn applyFieldPart(
    part: []const u8,
    field: []bool,
    min_value: u8,
    max_value: u8,
    map_seven_to_zero: bool,
) CronError!void {
    if (part.len == 0) return error.InvalidField;

    var range_part = part;
    var step: u8 = 1;
    if (std.mem.indexOfScalar(u8, part, '/')) |slash_idx| {
        range_part = part[0..slash_idx];
        const step_part = part[slash_idx + 1 ..];
        if (step_part.len == 0) return error.InvalidStep;

        const parsed_step = parseNumeric(step_part) catch return error.InvalidStep;
        if (parsed_step == 0) return error.InvalidStep;
        step = parsed_step;
    }

    var start: u8 = min_value;
    var end: u8 = max_value;

    if (!std.mem.eql(u8, range_part, "*")) {
        if (std.mem.indexOfScalar(u8, range_part, '-')) |dash_idx| {
            if (dash_idx == 0 or dash_idx + 1 >= range_part.len) return error.InvalidRange;
            start = parseNumeric(range_part[0..dash_idx]) catch return error.InvalidValue;
            end = parseNumeric(range_part[dash_idx + 1 ..]) catch return error.InvalidValue;
        } else {
            const value = parseNumeric(range_part) catch return error.InvalidValue;
            start = value;
            end = value;
        }
    }

    if (map_seven_to_zero and start == 7) start = 0;
    if (map_seven_to_zero and end == 7) end = 0;

    if (start < min_value or start > max_value) return error.InvalidValue;
    if (end < min_value or end > max_value) return error.InvalidValue;

    if (start <= end) {
        var current = start;
        while (current <= end) : (current +%= step) {
            field[current] = true;
            if (end - current < step) break;
        }
        return;
    }

    if (!map_seven_to_zero) return error.InvalidRange;

    var first = start;
    while (first <= max_value) : (first +%= step) {
        field[first] = true;
        if (max_value - first < step) break;
    }

    var second = min_value;
    while (second <= end) : (second +%= step) {
        field[second] = true;
        if (end - second < step) break;
    }
}

fn parseNumeric(text: []const u8) !u8 {
    if (text.len == 0) return error.InvalidValue;
    return std.fmt.parseInt(u8, text, 10);
}

fn makeLocalEpoch(
    year: c_int,
    month: c_int,
    day: c_int,
    hour: c_int,
    minute: c_int,
    second: c_int,
) !i64 {
    var tm_value: c.struct_tm = std.mem.zeroInit(c.struct_tm, .{});
    tm_value.tm_year = year - 1900;
    tm_value.tm_mon = month - 1;
    tm_value.tm_mday = day;
    tm_value.tm_hour = hour;
    tm_value.tm_min = minute;
    tm_value.tm_sec = second;
    tm_value.tm_isdst = -1;

    const raw = c.mktime(&tm_value);
    if (raw < 0) return error.TimeConversionFailed;
    return std.math.cast(i64, raw) orelse error.TimeOutOfRange;
}

test "parseCronExpression accepts valid five-field cron" {
    const parsed = try parseCronExpression("*/15 9-17 * * 1-5");
    try std.testing.expect(parsed.minutes[0]);
    try std.testing.expect(parsed.minutes[15]);
    try std.testing.expect(parsed.hours[9]);
    try std.testing.expect(parsed.hours[17]);
    try std.testing.expect(parsed.days_of_week[1]);
    try std.testing.expect(parsed.days_of_week[5]);
}

test "parseCronExpression rejects invalid cron" {
    try std.testing.expectError(error.InvalidExpression, parseCronExpression("* * * *"));
    try std.testing.expectError(error.InvalidValue, parseCronExpression("* * * * 9"));
}

test "nextRunAt finds next matching minute" {
    const base = try makeLocalEpoch(2026, 1, 10, 10, 29, 0);
    const expected = try makeLocalEpoch(2026, 1, 10, 10, 30, 0);
    const actual = try nextRunAt("30 10 * * *", base);
    try std.testing.expect(actual != null);
    try std.testing.expectEqual(expected, actual.?);
}
