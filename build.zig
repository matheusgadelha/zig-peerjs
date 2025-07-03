const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Add websocket dependency
    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add websocket import to lib module
    lib_mod.addImport("websocket", websocket_dep.module("websocket"));

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("zig_peerjs_connect_lib", lib_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig_peerjs_connect",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "zig_peerjs_connect",
        .root_module = exe_mod,
    });

    // Chat demo executable
    const chat_mod = b.createModule(.{
        .root_source_file = b.path("src/chat_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_mod.addImport("zig_peerjs_connect_lib", lib_mod);

    const chat_exe = b.addExecutable(.{
        .name = "zig_peerjs_chat",
        .root_module = chat_mod,
    });

    // Simple server executable
    const simple_server_mod = b.createModule(.{
        .root_source_file = b.path("src/simple_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_server_mod.addImport("zig_peerjs_connect_lib", lib_mod);

    const simple_server_exe = b.addExecutable(.{
        .name = "simple_server",
        .root_module = simple_server_mod,
    });

    // Simple client executable
    const simple_client_mod = b.createModule(.{
        .root_source_file = b.path("src/simple_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_client_mod.addImport("zig_peerjs_connect_lib", lib_mod);

    const simple_client_exe = b.addExecutable(.{
        .name = "simple_client",
        .root_module = simple_client_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);
    b.installArtifact(chat_exe);
    b.installArtifact(simple_server_exe);
    b.installArtifact(simple_client_exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Chat demo run step
    const chat_run_cmd = b.addRunArtifact(chat_exe);
    chat_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        chat_run_cmd.addArgs(args);
    }
    const chat_run_step = b.step("chat", "Run the chat demo");
    chat_run_step.dependOn(&chat_run_cmd.step);

    // Simple server run step
    const simple_server_run_cmd = b.addRunArtifact(simple_server_exe);
    simple_server_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        simple_server_run_cmd.addArgs(args);
    }
    const simple_server_run_step = b.step("server", "Run the simple server");
    simple_server_run_step.dependOn(&simple_server_run_cmd.step);

    // Simple client run step
    const simple_client_run_cmd = b.addRunArtifact(simple_client_exe);
    simple_client_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        simple_client_run_cmd.addArgs(args);
    }
    const simple_client_run_step = b.step("client", "Run the simple client");
    simple_client_run_step.dependOn(&simple_client_run_cmd.step);

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.root_module.addImport("websocket", websocket_dep.module("websocket"));

    // Token tests
    const token_tests = b.addTest(.{
        .root_source_file = b.path("src/token_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    token_tests.root_module.addImport("websocket", websocket_dep.module("websocket"));

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const run_token_tests = b.addRunArtifact(token_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_token_tests.step);
    
    // PeerJS Example
    const peerjs_example = b.addExecutable(.{
        .name = "peerjs_example",
        .root_source_file = b.path("src/peerjs_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    peerjs_example.root_module.addImport("websocket", websocket_dep.module("websocket"));

    const install_peerjs_example = b.addInstallArtifact(peerjs_example, .{});
    b.getInstallStep().dependOn(&install_peerjs_example.step);
}
