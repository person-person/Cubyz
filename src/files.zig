const std = @import("std");
const Allocator = std.mem.Allocator;

const main = @import("root");
const JsonElement = main.JsonElement;

pub fn read(allocator: Allocator, path: []const u8) ![]u8 {
	return cwd().read(allocator, path);
}

pub fn readToJson(allocator: Allocator, path: []const u8) !JsonElement {
	return cwd().readToJson(allocator, path);
}

pub fn write(path: []const u8, data: []const u8) !void {
	try cwd().write(path, data);
}

pub fn writeJson(path: []const u8, json: JsonElement) !void {
	try cwd().writeJson(path, json);
}

pub fn openDir(path: []const u8) !Dir {
	var dir = try std.fs.cwd().makeOpenPath(path, .{});
	return Dir {
		.dir = dir,
	};
}

fn cwd() Dir {
	return Dir {
		.dir = std.fs.cwd(),
	};
}

pub const Dir = struct {
	dir: std.fs.Dir,

	pub fn close(self: *Dir) void {
		self.dir.close();
	}

	pub fn read(self: Dir, allocator: Allocator, path: []const u8) ![]u8 {
		const file = try self.dir.openFile(path, .{});
		defer file.close();
		return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
	}

	pub fn readToJson(self: Dir, allocator: Allocator, path: []const u8) !JsonElement {
		const string = try self.read(main.threadAllocator, path);
		defer main.threadAllocator.free(string);
		return JsonElement.parseFromString(allocator, string);
	}

	pub fn write(self: Dir, path: []const u8, data: []const u8) !void {
		const file = try self.dir.createFile(path, .{});
		defer file.close();
		try file.writeAll(data);
	}

	pub fn writeJson(self: Dir, path: []const u8, json: JsonElement) !void {
		const string = try json.toString(main.threadAllocator);
		defer main.threadAllocator.free(string);
		try self.write(path, string);
	}

	pub fn hasFile(self: Dir, path: []const u8) bool {
		const file = self.dir.openFile(path, .{}) catch return false;
		file.close();
		return true;
	}
};