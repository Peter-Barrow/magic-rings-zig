const std = @import("std");
const knownFolders = @import("known-folders");
const MAX_PATH_LENGTH = std.fs.max_path_bytes;
const MAX_NAME_LENGTH = std.fs.MAX_NAME_BYTES;

pub const ConfigFields = struct {
    const Self = @This();

    /// Configuration structure for the application
    ///
    /// Fields:
    ///   name: Name of the configuration
    ///   shm_path: Path to shared memory
    ///   num_connections: Number of connections
    ///   library_version: Version of the library
    ///   shm_size: Size of shared memory
    project_name: []const u8,
    name: []const u8,
    shm_path: []const u8,
    num_connections: usize,
    library_version: []const u8,
    shm_size: usize,

    // Comptime fields derived from ElementType
    element_size: u32,
    element_type: []const u8,

    /// Initialize a new configuration instance
    ///
    /// Args:
    ///   name: Name of the configuration
    ///   shm_path: Path to shared memory
    ///   shm_size: Size of shared memory
    ///
    /// Returns:
    ///   A new instance of the configuration struct
    pub fn init(
        project_name: []const u8,
        name: []const u8,
        shm_path: []const u8,
        shm_size: usize,
        element_size: comptime_int,
        element_type: []const u8,
    ) Self {
        return Self{
            .project_name = project_name,
            .name = name,
            .shm_path = shm_path,
            .num_connections = 0,
            .library_version = "1.0.0", // Replace "1.0.0" with the actual version of your library
            .shm_size = shm_size,
            .element_size = element_size,
            .element_type = element_type,
        };
    }

    /// Generates the full path for the configuration file
    ///
    /// Args:
    ///   allocator: Memory allocator to use for string operations
    ///   name: Name of the configuration file
    ///
    /// Returns:
    ///   The full path to the configuration file as a string
    fn makeFilePath(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        const config_dir = blk: {
            // knownFolders.getPath(...) can return null, this however should never happen
            // in the case it does raise an error
            const conf_dir = try knownFolders.getPath(allocator, .local_configuration);
            if (conf_dir) |cf| break :blk cf;

            return error.NoLocalConfigurationForSystem;
        };

        defer allocator.free(config_dir);

        const app_config_dir = try std.fs.path.join(
            allocator,
            &[_][]const u8{ config_dir, self.project_name },
        );
        defer allocator.free(app_config_dir);

        const file_name = try std.fmt.allocPrint(allocator, "{s}_config.json", .{self.name});
        defer allocator.free(file_name);

        std.debug.assert(file_name.len <= MAX_NAME_LENGTH);

        const file_path = try std.fs.path.join(
            allocator,
            &[_][]const u8{ app_config_dir, file_name },
        );

        std.debug.assert(file_path.len <= MAX_PATH_LENGTH);

        return file_path;
    }

    /// Converts the Config struct to a JSON string
    ///
    /// Args:
    ///   allocator: Memory allocator to use for JSON string creation
    ///
    /// Returns:
    ///   A JSON string representation of the Config struct
    pub fn toJson(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        const json_value = try std.json.stringify(self, .{}, allocator);
        return json_value;
    }

    /// Writes the Config struct to a JSON file in the local configuration directory
    ///
    /// Args:
    ///   allocator: Memory allocator to use for file operations
    ///
    /// Returns:
    ///   void, or an error if the write operation fails
    pub fn writeConfig(self: *const Self, allocator: std.mem.Allocator) !void {
        const file_path = try self.makeFilePath(allocator);
        defer allocator.free(file_path);

        const json_data = try self.toJson(allocator);
        defer allocator.free(json_data);

        try std.fs.cwd().writeFile(file_path, json_data);
    }

    /// Loads a Config struct from a JSON file in the local configuration directory
    ///
    /// Args:
    ///   allocator: Memory allocator to use for file operations and JSON parsing
    ///   project_name: Name of the project
    ///   name: Name of the configuration file to load
    ///
    /// Returns:
    ///   A Config struct populated with data from the JSON file, or an error if the load operation fails
    pub fn loadConfig(allocator: std.mem.Allocator, project_name: []const u8, name: []const u8) !Self {
        var self = Self{
            .project_name = project_name,
            .name = name,
            .shm_path = undefined,
            .num_connections = undefined,
            .library_version = undefined,
            .shm_size = undefined,
            .element_size = undefined,
            .element_type = undefined,
        };

        const file_path = try self.makeFilePath(allocator);
        defer allocator.free(file_path);

        const file_contents = try std.fs.cwd().readFileAlloc(
            allocator,
            file_path,
            std.math.maxInt(usize),
        );
        defer allocator.free(file_contents);

        var stream = std.json.TokenStream.init(file_contents);
        return try std.json.parse(Self, &stream, .{ .allocator = allocator });
    }
};

pub fn makeConfig(comptime project_name: []const u8, comptime ElementType: type) ConfigFields {
    return ConfigFields.init(
        project_name,
        "", // name will be set later
        "", // shm_path will be set later
        0, // shm_size will be set later
        @sizeOf(ElementType),
        @typeName(ElementType),
    );
}

test "getConfigFilePath" {
    const allocator = std.testing.allocator;

    var test_config = ConfigFields.init(
        "test_project",
        "test_config",
        "/tmp/test_shm",
        1024,
        @sizeOf(u32),
        @typeName(u32),
    );
    const file_path = try test_config.makeFilePath(allocator);
    defer allocator.free(file_path);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fmt.bufPrintZ(
        &buffer,
        "{s}{s}{s}_config.json",
        .{
            test_config.project_name,
            [1]u8{std.fs.path.sep},
            test_config.name,
        },
    );

    std.debug.print("Config Path:\t{s}\n", .{target});
    std.debug.print("Config Path:\t{s}\n", .{file_path});

    try std.testing.expect(std.mem.endsWith(u8, file_path, target));
}
