//! @file sql.zig
//! @brief SQL92 filter and query evaluation engine for ContentFilteredTopic and QueryCondition.
//!
//! Name: Data Distribution Zervice
//! Author: 0xGodyr

const std = @import("std");

pub const Sql = struct {
    pub const Sql92 = Sql;
    pub fn evaluate(comptime T: type, data_opt: ?T, filter_expr: []const u8) bool {
        return evaluateWithParams(T, data_opt, filter_expr, &.{});
    }

    pub fn evaluateWithParams(comptime T: type, data_opt: ?T, filter_expr: []const u8, params: []const []const u8) bool {
        if (data_opt == null) return true;
        const data = data_opt.?;
        if (@typeInfo(T) != .@"struct") return true;
        if (filter_expr.len == 0) return true;

        var parser = Parser{ .text = filter_expr, .pos = 0, .params = params };
        return parser.parseExpr(T, data) catch true;
    }

    const Parser = struct {
        text: []const u8,
        pos: usize,
        params: []const []const u8 = &.{},

        fn skipWhitespace(self: *Parser) void {
            while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) {
                self.pos += 1;
            }
        }

        fn matchKw(self: *Parser, kw: []const u8) bool {
            self.skipWhitespace();
            if (self.pos + kw.len <= self.text.len) {
                if (std.ascii.eqlIgnoreCase(self.text[self.pos .. self.pos + kw.len], kw)) {
                    // Make sure it's followed by boundary
                    if (self.pos + kw.len == self.text.len or
                        std.ascii.isWhitespace(self.text[self.pos + kw.len]) or
                        self.text[self.pos + kw.len] == '(' or
                        self.text[self.pos + kw.len] == ')' or
                        self.text[self.pos + kw.len] == ',')
                    {
                        self.pos += kw.len;
                        return true;
                    }
                }
            }
            return false;
        }

        fn parseExpr(self: *Parser, comptime T: type, data: T) error{ParseError}!bool {
            var result = try self.parseTerm(T, data);
            while (true) {
                if (self.matchKw("OR")) {
                    const right = try self.parseTerm(T, data);
                    result = result or right;
                } else {
                    break;
                }
            }
            return result;
        }

        fn parseTerm(self: *Parser, comptime T: type, data: T) error{ParseError}!bool {
            var result = try self.parseFactor(T, data);
            while (true) {
                if (self.matchKw("AND")) {
                    const right = try self.parseFactor(T, data);
                    result = result and right;
                } else {
                    break;
                }
            }
            return result;
        }

        fn parseFactor(self: *Parser, comptime T: type, data: T) error{ParseError}!bool {
            self.skipWhitespace();
            if (self.matchKw("NOT")) {
                return !(try self.parseFactor(T, data));
            }
            if (self.pos < self.text.len and self.text[self.pos] == '(') {
                self.pos += 1;
                const result = try self.parseExpr(T, data);
                self.skipWhitespace();
                if (self.pos < self.text.len and self.text[self.pos] == ')') {
                    self.pos += 1;
                }
                return result;
            }
            return try self.parseCondition(T, data);
        }

        fn parseIdentifier(self: *Parser) ?[]const u8 {
            self.skipWhitespace();
            const start = self.pos;
            while (self.pos < self.text.len and (std.ascii.isAlphanumeric(self.text[self.pos]) or self.text[self.pos] == '_')) {
                self.pos += 1;
            }
            if (self.pos > start) return self.text[start..self.pos];
            return null;
        }

        fn parseOperator(self: *Parser) ?[]const u8 {
            self.skipWhitespace();
            const ops = [_][]const u8{ "<>", "<=", ">=", "==", "=", "<", ">", "NOT IN", "IN", "LIKE", "MATCH", "BETWEEN" };
            for (ops) |op| {
                if (std.ascii.isAlphabetic(op[0])) {
                    if (self.matchKw(op)) return op;
                } else {
                    if (self.pos + op.len <= self.text.len and std.mem.eql(u8, self.text[self.pos .. self.pos + op.len], op)) {
                        self.pos += op.len;
                        return op;
                    }
                }
            }
            return null;
        }

        fn parseValueString(self: *Parser) ?[]const u8 {
            self.skipWhitespace();
            if (self.pos >= self.text.len) return null;

            // Quoted string '...'
            if (self.text[self.pos] == '\'') {
                self.pos += 1;
                const start = self.pos;
                while (self.pos < self.text.len and self.text[self.pos] != '\'') {
                    self.pos += 1;
                }
                const val = self.text[start..self.pos];
                if (self.pos < self.text.len) self.pos += 1;
                return val;
            }

            // Parameter substitution %0, %1, ...
            if (self.text[self.pos] == '%') {
                self.pos += 1;
                const start = self.pos;
                while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) {
                    self.pos += 1;
                }
                if (self.pos > start) {
                    const idx_str = self.text[start..self.pos];
                    const idx = std.fmt.parseInt(usize, idx_str, 10) catch return null;
                    if (idx < self.params.len) {
                        var p = self.params[idx];
                        if (p.len >= 2 and p[0] == '\'' and p[p.len - 1] == '\'') {
                            p = p[1 .. p.len - 1];
                        }
                        return p;
                    }
                    return null;
                }
                return null;
            }

            // Unquoted token
            const start = self.pos;
            while (self.pos < self.text.len and
                !std.ascii.isWhitespace(self.text[self.pos]) and
                self.text[self.pos] != ')' and
                self.text[self.pos] != ',' and
                self.text[self.pos] != '(')
            {
                self.pos += 1;
            }
            if (self.pos > start) return self.text[start..self.pos];
            return null;
        }

        fn parseCondition(self: *Parser, comptime T: type, data: T) error{ParseError}!bool {
            const field_name = self.parseIdentifier() orelse return error.ParseError;
            const op = self.parseOperator() orelse return error.ParseError;

            // Handle IN and NOT IN lists
            if (std.mem.eql(u8, op, "IN") or std.mem.eql(u8, op, "NOT IN")) {
                return try self.parseInCondition(T, data, field_name, std.mem.eql(u8, op, "NOT IN"));
            }

            const val_str = self.parseValueString() orelse return error.ParseError;

            if (std.mem.eql(u8, op, "BETWEEN")) {
                if (!self.matchKw("AND")) return error.ParseError;
                const upper_bound_str = self.parseValueString() orelse return error.ParseError;
                return self.checkFieldBetween(T, data, field_name, val_str, upper_bound_str);
            }

            return self.checkFieldOp(T, data, field_name, op, val_str);
        }

        fn parseInCondition(self: *Parser, comptime T: type, data: T, field_name: []const u8, is_not_in: bool) error{ParseError}!bool {
            self.skipWhitespace();
            if (self.pos >= self.text.len or self.text[self.pos] != '(') return error.ParseError;
            self.pos += 1;

            var in_matched = false;
            var item_count: usize = 0;

            while (true) {
                self.skipWhitespace();
                if (self.pos < self.text.len and self.text[self.pos] == ')') {
                    self.pos += 1;
                    break;
                }

                const item_str = self.parseValueString() orelse return error.ParseError;
                item_count += 1;

                if (!in_matched) {
                    if (self.checkFieldOp(T, data, field_name, "=", item_str) catch false) {
                        in_matched = true;
                    }
                }

                self.skipWhitespace();
                if (self.pos < self.text.len and self.text[self.pos] == ',') {
                    self.pos += 1;
                } else if (self.pos < self.text.len and self.text[self.pos] == ')') {
                    self.pos += 1;
                    break;
                } else {
                    return error.ParseError;
                }
            }

            if (item_count == 0) return error.ParseError;
            return if (is_not_in) !in_matched else in_matched;
        }

        fn checkFieldBetween(self: *Parser, comptime T: type, data: T, field_name: []const u8, lower_str: []const u8, upper_str: []const u8) error{ParseError}!bool {
            _ = self;
            inline for (@typeInfo(T).@"struct".field_names) |f_name| {
                if (std.mem.eql(u8, f_name, field_name)) {
                    const FieldType = @TypeOf(@field(data, f_name));
                    switch (@typeInfo(FieldType)) {
                        .int, .comptime_int => {
                            const lower = std.fmt.parseInt(i128, lower_str, 10) catch {
                                const f_low = std.fmt.parseFloat(f64, lower_str) catch return error.ParseError;
                                const f_up = std.fmt.parseFloat(f64, upper_str) catch return error.ParseError;
                                const f_val = @as(f64, @floatFromInt(@field(data, f_name)));
                                return f_val >= f_low and f_val <= f_up;
                            };
                            const upper = std.fmt.parseInt(i128, upper_str, 10) catch return error.ParseError;
                            const data_val = @as(i128, @intCast(@field(data, f_name)));
                            return data_val >= lower and data_val <= upper;
                        },
                        .float, .comptime_float => {
                            const lower = std.fmt.parseFloat(f64, lower_str) catch return error.ParseError;
                            const upper = std.fmt.parseFloat(f64, upper_str) catch return error.ParseError;
                            const data_val = @as(f64, @floatCast(@field(data, f_name)));
                            return data_val >= lower and data_val <= upper;
                        },
                        else => return error.ParseError,
                    }
                }
            }
            return true;
        }

        fn checkFieldOp(self: *Parser, comptime T: type, data: T, field_name: []const u8, op: []const u8, val_str: []const u8) error{ParseError}!bool {
            _ = self;
            var matched_field = false;
            inline for (@typeInfo(T).@"struct".field_names) |f_name| {
                if (std.mem.eql(u8, f_name, field_name)) {
                    matched_field = true;
                    const FieldType = @TypeOf(@field(data, f_name));
                    switch (@typeInfo(FieldType)) {
                        .bool => {
                            const data_val = @field(data, f_name);
                            const val = if (std.ascii.eqlIgnoreCase(val_str, "true") or std.mem.eql(u8, val_str, "1"))
                                true
                            else if (std.ascii.eqlIgnoreCase(val_str, "false") or std.mem.eql(u8, val_str, "0"))
                                false
                            else
                                return error.ParseError;

                            if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return data_val == val;
                            if (std.mem.eql(u8, op, "<>") or std.mem.eql(u8, op, "!=")) return data_val != val;
                            return error.ParseError;
                        },
                        .int, .comptime_int => {
                            const val = std.fmt.parseInt(i128, val_str, 10) catch {
                                const f_val = std.fmt.parseFloat(f64, val_str) catch return error.ParseError;
                                const data_val = @as(f64, @floatFromInt(@field(data, f_name)));
                                if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return data_val == f_val;
                                if (std.mem.eql(u8, op, "<>") or std.mem.eql(u8, op, "!=")) return data_val != f_val;
                                if (std.mem.eql(u8, op, ">")) return data_val > f_val;
                                if (std.mem.eql(u8, op, "<")) return data_val < f_val;
                                if (std.mem.eql(u8, op, ">=")) return data_val >= f_val;
                                if (std.mem.eql(u8, op, "<=")) return data_val <= f_val;
                                return error.ParseError;
                            };
                            const data_val = @as(i128, @intCast(@field(data, f_name)));
                            if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return data_val == val;
                            if (std.mem.eql(u8, op, "<>") or std.mem.eql(u8, op, "!=")) return data_val != val;
                            if (std.mem.eql(u8, op, ">")) return data_val > val;
                            if (std.mem.eql(u8, op, "<")) return data_val < val;
                            if (std.mem.eql(u8, op, ">=")) return data_val >= val;
                            if (std.mem.eql(u8, op, "<=")) return data_val <= val;
                            return error.ParseError;
                        },
                        .float, .comptime_float => {
                            const val = std.fmt.parseFloat(f64, val_str) catch return error.ParseError;
                            const data_val = @as(f64, @floatCast(@field(data, f_name)));
                            if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return data_val == val;
                            if (std.mem.eql(u8, op, "<>") or std.mem.eql(u8, op, "!=")) return data_val != val;
                            if (std.mem.eql(u8, op, ">")) return data_val > val;
                            if (std.mem.eql(u8, op, "<")) return data_val < val;
                            if (std.mem.eql(u8, op, ">=")) return data_val >= val;
                            if (std.mem.eql(u8, op, "<=")) return data_val <= val;
                            return error.ParseError;
                        },
                        .array => |arr_info| {
                            if (arr_info.child != u8) return true;
                            const raw_str = @as([]const u8, @field(data, f_name)[0..]);
                            const data_str = std.mem.sliceTo(raw_str, 0);
                            return evaluateStringOp(data_str, op, val_str);
                        },
                        .pointer => |ptr_info| {
                            if (ptr_info.child != u8) return true;
                            const data_str = @as([]const u8, @field(data, f_name));
                            return evaluateStringOp(data_str, op, val_str);
                        },
                        .@"enum" => {
                            const data_val = @field(data, f_name);
                            const tag_name = @tagName(data_val);
                            if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
                                if (std.ascii.eqlIgnoreCase(tag_name, val_str)) return true;
                                if (std.fmt.parseInt(i128, val_str, 10)) |val_int| {
                                    return @backingInt(data_val) == val_int;
                                } else |_| {}
                                return false;
                            }
                            if (std.mem.eql(u8, op, "<>") or std.mem.eql(u8, op, "!=")) {
                                if (std.ascii.eqlIgnoreCase(tag_name, val_str)) return false;
                                if (std.fmt.parseInt(i128, val_str, 10)) |val_int| {
                                    return @backingInt(data_val) != val_int;
                                } else |_| {}
                                return true;
                            }
                            return error.ParseError;
                        },
                        else => return true,
                    }
                }
            }
            return !matched_field;
        }

        fn evaluateStringOp(data_str: []const u8, op: []const u8, val_str: []const u8) bool {
            if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, data_str, val_str);
            if (std.mem.eql(u8, op, "<>") or std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, data_str, val_str);
            if (std.ascii.eqlIgnoreCase(op, "LIKE") or std.ascii.eqlIgnoreCase(op, "MATCH")) {
                if (val_str.len == 0) return data_str.len == 0;

                const starts_wild = val_str[0] == '*' or val_str[0] == '%';
                const ends_wild = val_str[val_str.len - 1] == '*' or val_str[val_str.len - 1] == '%';

                if (starts_wild and ends_wild and val_str.len >= 2) {
                    const sub = val_str[1 .. val_str.len - 1];
                    return std.mem.indexOf(u8, data_str, sub) != null;
                } else if (ends_wild) {
                    return std.mem.startsWith(u8, data_str, val_str[0 .. val_str.len - 1]);
                } else if (starts_wild) {
                    return std.mem.endsWith(u8, data_str, val_str[1..]);
                }
                return std.mem.eql(u8, data_str, val_str);
            }
            return false;
        }
    };
};

pub const Sql92 = Sql;

test "Sql92 with numeric array fields and strings" {
    const TestStruct = struct {
        id: u32,
        name: [8]u8,
        scores: [3]u32,
    };
    const sample = TestStruct{
        .id = 42,
        .name = [_]u8{ 'a', 'l', 'i', 'c', 'e', 0, 0, 0 },
        .scores = [_]u32{ 10, 20, 30 },
    };
    try std.testing.expect(Sql92.evaluate(TestStruct, sample, "id = 42"));
    try std.testing.expect(!Sql92.evaluate(TestStruct, sample, "id = 43"));
}

test "Sql92 IN and NOT IN operators" {
    const TestStruct = struct {
        id: u32,
        category: []const u8,
    };
    const sample = TestStruct{
        .id = 2,
        .category = "sensors",
    };

    // IN with integer values
    try std.testing.expect(Sql92.evaluate(TestStruct, sample, "id IN (1, 2, 3)"));
    try std.testing.expect(!Sql92.evaluate(TestStruct, sample, "id IN (10, 20, 30)"));

    // NOT IN with integer values
    try std.testing.expect(!Sql92.evaluate(TestStruct, sample, "id NOT IN (1, 2, 3)"));
    try std.testing.expect(Sql92.evaluate(TestStruct, sample, "id NOT IN (10, 20, 30)"));

    // IN with string values
    try std.testing.expect(Sql92.evaluate(TestStruct, sample, "category IN ('motors', 'sensors', 'actuators')"));
    try std.testing.expect(!Sql92.evaluate(TestStruct, sample, "category IN ('telemetry', 'logging')"));
}

test "Sql92 expression parameterization %0, %1" {
    const TestStruct = struct {
        id: u32,
        temp: f32,
        name: []const u8,
    };
    const sample = TestStruct{
        .id = 101,
        .temp = 85.5,
        .name = "chassis_sensor",
    };

    const params = [_][]const u8{ "101", "80.0", "'chassis_sensor'" };

    // Equality with parameters
    try std.testing.expect(Sql92.evaluateWithParams(TestStruct, sample, "id = %0", &params));
    try std.testing.expect(Sql92.evaluateWithParams(TestStruct, sample, "temp > %1", &params));
    try std.testing.expect(Sql92.evaluateWithParams(TestStruct, sample, "name = %2", &params));

    // Compound expression with parameters
    try std.testing.expect(Sql92.evaluateWithParams(TestStruct, sample, "id = %0 AND temp > %1 AND name = %2", &params));

    // IN with parameters
    const in_params = [_][]const u8{ "50", "101", "200" };
    try std.testing.expect(Sql92.evaluateWithParams(TestStruct, sample, "id IN (%0, %1, %2)", &in_params));

    // BETWEEN with parameters
    const between_params = [_][]const u8{ "100", "110" };
    try std.testing.expect(Sql92.evaluateWithParams(TestStruct, sample, "id BETWEEN %0 AND %1", &between_params));
}

test "Sql92 LIKE and MATCH patterns" {
    const TestStruct = struct {
        tag: []const u8,
    };
    const sample = TestStruct{ .tag = "radar_front_sensor" };

    // Prefix wildcard
    try std.testing.expect(Sql92.evaluate(TestStruct, sample, "tag LIKE 'radar*'"));
    try std.testing.expect(Sql92.evaluate(TestStruct, sample, "tag LIKE 'radar%'"));

    // Suffix wildcard
    try std.testing.expect(Sql92.evaluate(TestStruct, sample, "tag LIKE '*sensor'"));
    try std.testing.expect(Sql92.evaluate(TestStruct, sample, "tag LIKE '%sensor'"));

    // Substring wildcard
    try std.testing.expect(Sql92.evaluate(TestStruct, sample, "tag LIKE '*front*'"));
    try std.testing.expect(Sql92.evaluate(TestStruct, sample, "tag LIKE '%front%'"));

    // Mismatches
    try std.testing.expect(!Sql92.evaluate(TestStruct, sample, "tag LIKE 'lidar*'"));
    try std.testing.expect(!Sql92.evaluate(TestStruct, sample, "tag LIKE '*rear'"));
}
