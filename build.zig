const std = @import("std");

fn addPackageCSourceFiles(exe: *std.Build.Step.Compile, dep: *std.Build.Dependency, files: []const []const u8, flags: []const []const u8) void {
	for(files) |file| {
		exe.addCSourceFile(.{ .file =  dep.path(file), .flags = flags});
	}
}

pub fn build(b: *std.build.Builder) !void {
	// Standard target options allows the person running `zig build` to choose
	// what target to build for. Here we do not override the defaults, which
	// means any target is allowed, and the default is native. Other options
	// for restricting supported target set are available.
	const target = b.standardTargetOptions(.{});

	// Standard release options allow the person running `zig build` to select
	// between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
	const optimize = b.standardOptimizeOption(.{});
	const exe = b.addExecutable(.{
		.name = "Cubyzig",
		.root_source_file = .{.path = "src/main.zig"},
		.target = target,
		.optimize = optimize,
	});
	exe.addIncludePath(.{.path = "include"});
	exe.linkLibC();
	{ // compile glfw from source:
		if(target.getOsTag() == .windows) {
			exe.addCSourceFiles(&[_][]const u8 {
				"lib/glfw/src/win32_init.c", "lib/glfw/src/win32_joystick.c", "lib/glfw/src/win32_monitor.c", "lib/glfw/src/win32_time.c", "lib/glfw/src/win32_thread.c", "lib/glfw/src/win32_window.c", "lib/glfw/src/wgl_context.c", "lib/glfw/src/egl_context.c", "lib/glfw/src/osmesa_context.c", "lib/glfw/src/context.c", "lib/glfw/src/init.c", "lib/glfw/src/input.c", "lib/glfw/src/monitor.c", "lib/glfw/src/vulkan.c", "lib/glfw/src/window.c"
			}, &[_][]const u8{"-g", "-std=c99", "-D_GLFW_WIN32"});
			exe.linkSystemLibrary("gdi32");
			exe.linkSystemLibrary("opengl32");
			exe.linkSystemLibrary("ws2_32");
		} else if(target.getOsTag() == .linux) {
			// TODO: if(isWayland) {
			//	exe.addCSourceFiles(&[_][]const u8 {
			//		"lib/glfw/src/linux_joystick.c", "lib/glfw/src/wl_init.c", "lib/glfw/src/wl_monitor.c", "lib/glfw/src/wl_window.c", "lib/glfw/src/posix_time.c", "lib/glfw/src/posix_thread.c", "lib/glfw/src/xkb_unicode.c", "lib/glfw/src/egl_context.c", "lib/glfw/src/osmesa_context.c", "lib/glfw/src/context.c", "lib/glfw/src/init.c", "lib/glfw/src/input.c", "lib/glfw/src/monitor.c", "lib/glfw/src/vulkan.c", "lib/glfw/src/window.c"
			//	}, &[_][]const u8{"-g",});
			//} else {
				exe.addCSourceFiles(&[_][]const u8 {
					"lib/glfw/src/linux_joystick.c", "lib/glfw/src/x11_init.c", "lib/glfw/src/x11_monitor.c", "lib/glfw/src/x11_window.c", "lib/glfw/src/xkb_unicode.c", "lib/glfw/src/posix_time.c", "lib/glfw/src/posix_thread.c", "lib/glfw/src/glx_context.c", "lib/glfw/src/egl_context.c", "lib/glfw/src/osmesa_context.c", "lib/glfw/src/context.c", "lib/glfw/src/init.c", "lib/glfw/src/input.c", "lib/glfw/src/monitor.c", "lib/glfw/src/vulkan.c", "lib/glfw/src/window.c"
				}, &[_][]const u8{"-g", "-std=c99", "-D_GLFW_X11"});
				exe.linkSystemLibrary("x11");
			//}
			exe.linkSystemLibrary("GL");
		} else {
			std.log.err("Unsupported target: {}\n", .{ target.getOsTag() });
		}
	}
	{ // compile portaudio from source:
		const portaudio = b.dependency("portaudio", .{
			.target = target,
			.optimize = optimize,
		});
		exe.addIncludePath(portaudio.path("include"));
		exe.addIncludePath(portaudio.path("src/common"));
		addPackageCSourceFiles(exe, portaudio, &[_][]const u8 {
			"src/common/pa_allocation.c",
			"src/common/pa_converters.c",
			"src/common/pa_cpuload.c",
			"src/common/pa_debugprint.c",
			"src/common/pa_dither.c",
			"src/common/pa_front.c",
			"src/common/pa_process.c",
			"src/common/pa_ringbuffer.c",
			"src/common/pa_stream.c",
			"src/common/pa_trace.c",
		}, &[_][]const u8{"-g", "-O3"});
		if(target.getOsTag() == .windows) {
			// windows:
			addPackageCSourceFiles(exe, portaudio, &[_][]const u8 {"src/os/win/pa_win_coinitialize.c", "src/os/win/pa_win_hostapis.c", "src/os/win/pa_win_util.c", "src/os/win/pa_win_waveformat.c", "src/os/win/pa_win_wdmks_utils.c", "src/os/win/pa_x86_plain_converters.c", }, &[_][]const u8{"-g", "-O3", "-DPA_USE_WASAPI"});
			exe.addIncludePath(portaudio.path("src/os/win"));
			exe.linkSystemLibrary("ole32");
			exe.linkSystemLibrary("winmm");
			exe.linkSystemLibrary("uuid");
			// WASAPI:
			addPackageCSourceFiles(exe, portaudio, &[_][]const u8 {"src/hostapi/wasapi/pa_win_wasapi.c"}, &[_][]const u8{"-g", "-O3"});
		} else if(target.getOsTag() == .linux) {
			// unix:
			addPackageCSourceFiles(exe, portaudio, &[_][]const u8 {"src/os/unix/pa_unix_hostapis.c", "src/os/unix/pa_unix_util.c"}, &[_][]const u8{"-g", "-O3", "-DPA_USE_ALSA"});
			exe.addIncludePath(portaudio.path("src/os/unix"));
			// ALSA:
			addPackageCSourceFiles(exe, portaudio, &[_][]const u8 {"src/hostapi/alsa/pa_linux_alsa.c"}, &[_][]const u8{"-g", "-O3"});
			exe.linkSystemLibrary("asound");
		} else {
			std.log.err("Unsupported target: {}\n", .{ target.getOsTag() });
		}
	}
	exe.addCSourceFiles(&[_][]const u8{"lib/glad.c", "lib/stb_image.c", "lib/stb_image_write.c", "lib/stb_vorbis.c"}, &[_][]const u8{"-g", "-O3"});
	exe.addAnonymousModule("gui", .{.source_file = .{.path = "src/gui/gui.zig"}});
	exe.addAnonymousModule("server", .{.source_file = .{.path = "src/server/server.zig"}});
	
	const mach_freetype_dep = b.dependency("mach_freetype", .{
		.target = target,
		.optimize = optimize,
	});
	exe.addModule("freetype", mach_freetype_dep.module("mach-freetype"));
	exe.addModule("harfbuzz", mach_freetype_dep.module("mach-harfbuzz"));
	@import("mach_freetype").linkFreetype(mach_freetype_dep.builder, exe);
	@import("mach_freetype").linkHarfbuzz(mach_freetype_dep.builder, exe);

	//exe.strip = true; // Improves compile-time
	//exe.sanitize_thread = true;
	exe.disable_stack_probing = true; // Improves tracing of stack overflow errors.
	b.installArtifact(exe);

	const run_cmd = b.addRunArtifact(exe);
	run_cmd.step.dependOn(b.getInstallStep());
	if (b.args) |args| {
		run_cmd.addArgs(args);
	}

	const run_step = b.step("run", "Run the app");
	run_step.dependOn(&run_cmd.step);

	const exe_tests = b.addTest(.{
		.root_source_file = .{ .path = "src/main.zig" },
		.target = target,
		.optimize = optimize,
	});

	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&exe_tests.step);
}
