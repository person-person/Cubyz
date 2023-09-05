const std = @import("std");
const Allocator = std.mem.Allocator;

const blocks = @import("blocks.zig");
const Block = blocks.Block;
const game = @import("game.zig");
const graphics = @import("graphics.zig");
const c = graphics.c;
const Shader = graphics.Shader;
const SSBO = graphics.SSBO;
const main = @import("main.zig");
const models = @import("models.zig");
const renderer = @import("renderer.zig");
const settings = @import("settings.zig");
const vec = @import("vec.zig");
const Vec2f = vec.Vec2f;
const Vec3i = vec.Vec3i;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const Mat4f = vec.Mat4f;

pub const chunkShift: u5 = 5;
pub const chunkShift2: u5 = chunkShift*2;
pub const chunkSize: u31 = 1 << chunkShift;
pub const chunkSizeIterator: [chunkSize]u0 = undefined;
pub const chunkVolume: u31 = 1 << 3*chunkShift;
pub const chunkMask: i32 = chunkSize - 1;

/// Contains a bunch of constants used to describe neighboring blocks.
pub const Neighbors = struct {
	/// How many neighbors there are.
	pub const neighbors: u3 = 6;
	/// Directions → Index
	pub const dirUp: u3 = 0;
	/// Directions → Index
	pub const dirDown: u3 = 1;
	/// Directions → Index
	pub const dirPosX: u3 = 2;
	/// Directions → Index
	pub const dirNegX: u3 = 3;
	/// Directions → Index
	pub const dirPosZ: u3 = 4;
	/// Directions → Index
	pub const dirNegZ: u3 = 5;
	/// Index to relative position
	pub const relX = [_]i32 {0, 0, 1, -1, 0, 0};
	/// Index to relative position
	pub const relY = [_]i32 {1, -1, 0, 0, 0, 0};
	/// Index to relative position
	pub const relZ = [_]i32 {0, 0, 0, 0, 1, -1};
	/// Index to bitMask for bitmap direction data
	pub const bitMask = [_]u6 {0x01, 0x02, 0x04, 0x08, 0x10, 0x20};
	/// To iterate over all neighbors easily
	pub const iterable = [_]u3 {0, 1, 2, 3, 4, 5};
	/// Marks the two dimension that are orthogonal
	pub const orthogonalComponents = [_]Vec3i {
		.{1, 0, 1},
		.{1, 0, 1},
		.{0, 1, 1},
		.{0, 1, 1},
		.{1, 1, 0},
		.{1, 1, 0},
	};

	pub const isPositive = [_]bool {true, false, true, false, true, false};
	pub const vectorComponent = [_]enum(u2){x = 0, y = 1, z = 2} {.y, .y, .x, .x, .z, .z};

	pub fn extractDirectionComponent(self: u3, in: anytype) @TypeOf(in[0]) {
		switch(self) {
			inline else => |val| {
				if(val >= 6) unreachable;
				return in[@intFromEnum(vectorComponent[val])];
			}
		}
	}
};

/// Gets the index of a given position inside this chunk.
fn getIndex(x: i32, y: i32, z: i32) u32 {
	std.debug.assert((x & chunkMask) == x and (y & chunkMask) == y and (z & chunkMask) == z);
	return (@as(u32, @intCast(x)) << chunkShift) | (@as(u32, @intCast(y)) << chunkShift2) | @as(u32, @intCast(z));
}
/// Gets the x coordinate from a given index inside this chunk.
fn extractXFromIndex(index: usize) i32 {
	return @intCast(index >> chunkShift & chunkMask);
}
/// Gets the y coordinate from a given index inside this chunk.
fn extractYFromIndex(index: usize) i32 {
	return @intCast(index >> chunkShift2 & chunkMask);
}
/// Gets the z coordinate from a given index inside this chunk.
fn extractZFromIndex(index: usize) i32 {
	return @intCast(index & chunkMask);
}

pub const ChunkPosition = struct {
	wx: i32,
	wy: i32,
	wz: i32,
	voxelSize: u31,
	
	pub fn hashCode(self: ChunkPosition) u32 {
		const shift: u5 = @truncate(@min(@ctz(self.wx), @ctz(self.wy), @ctz(self.wz)));
		return (((@as(u32, @bitCast(self.wx)) >> shift) *% 31 +% (@as(u32, @bitCast(self.wy)) >> shift)) *% 31 +% (@as(u32, @bitCast(self.wz)) >> shift)) *% 31 +% self.voxelSize; // TODO: Can I use one of zigs standard hash functions?
	}

	pub fn equals(self: ChunkPosition, other: anytype) bool {
		if(@typeInfo(@TypeOf(other)) == .Optional) {
			if(other) |notNull| {
				return self.equals(notNull);
			}
			return false;
		} else if(@typeInfo(@TypeOf(other)) == .Pointer) {
			return self.wx == other.pos.wx and self.wy == other.pos.wy and self.wz == other.pos.wz and self.voxelSize == other.pos.voxelSize;
		} else @compileError("Unsupported");
	}

	pub fn getMinDistanceSquared(self: ChunkPosition, playerPosition: Vec3d) f64 {
		var halfWidth: f64 = @floatFromInt(self.voxelSize*@divExact(chunkSize, 2));
		var dx = @fabs(@as(f64, @floatFromInt(self.wx)) + halfWidth - playerPosition[0]);
		var dy = @fabs(@as(f64, @floatFromInt(self.wy)) + halfWidth - playerPosition[1]);
		var dz = @fabs(@as(f64, @floatFromInt(self.wz)) + halfWidth - playerPosition[2]);
		dx = @max(0, dx - halfWidth);
		dy = @max(0, dy - halfWidth);
		dz = @max(0, dz - halfWidth);
		return dx*dx + dy*dy + dz*dz;
	}

	pub fn getMaxDistanceSquared(self: ChunkPosition, playerPosition: Vec3d) f64 {
		var halfWidth: f64 = @floatFromInt(self.voxelSize*@divExact(chunkSize, 2));
		var dx = @fabs(@as(f64, @floatFromInt(self.wx)) + halfWidth - playerPosition[0]);
		var dy = @fabs(@as(f64, @floatFromInt(self.wy)) + halfWidth - playerPosition[1]);
		var dz = @fabs(@as(f64, @floatFromInt(self.wz)) + halfWidth - playerPosition[2]);
		dx = dx + halfWidth;
		dy = dy + halfWidth;
		dz = dz + halfWidth;
		return dx*dx + dy*dy + dz*dz;
	}

	pub fn getCenterDistanceSquared(self: ChunkPosition, playerPosition: Vec3d) f64 {
		var halfWidth: f64 = @floatFromInt(self.voxelSize*@divExact(chunkSize, 2));
		var dx = @as(f64, @floatFromInt(self.wx)) + halfWidth - playerPosition[0];
		var dy = @as(f64, @floatFromInt(self.wy)) + halfWidth - playerPosition[1];
		var dz = @as(f64, @floatFromInt(self.wz)) + halfWidth - playerPosition[2];
		return dx*dx + dy*dy + dz*dz;
	}

	pub fn getPriority(self: ChunkPosition, playerPos: Vec3d) f32 {
		return -@as(f32, @floatCast(self.getMinDistanceSquared(playerPos)))/@as(f32, @floatFromInt(self.voxelSize*self.voxelSize)) + 2*@as(f32, @floatFromInt(std.math.log2_int(u31, self.voxelSize)*chunkSize*chunkSize));
	}
};

pub const Chunk = struct {
	pos: ChunkPosition,
	blocks: [chunkVolume]Block = undefined,

	wasChanged: bool = false,
	/// When a chunk is cleaned, it won't be saved by the ChunkManager anymore, so following changes need to be saved directly.
	wasCleaned: bool = false,
	generated: bool = false,

	width: u31,
	voxelSizeShift: u5,
	voxelSizeMask: i32,
	widthShift: u5,
	mutex: std.Thread.Mutex,

	pub fn init(self: *Chunk, pos: ChunkPosition) void {
		std.debug.assert((pos.voxelSize - 1 & pos.voxelSize) == 0);
		std.debug.assert(@mod(pos.wx, pos.voxelSize) == 0 and @mod(pos.wy, pos.voxelSize) == 0 and @mod(pos.wz, pos.voxelSize) == 0);
		const voxelSizeShift: u5 = @intCast(std.math.log2_int(u31, pos.voxelSize));
		self.* = Chunk {
			.pos = pos,
			.width = pos.voxelSize*chunkSize,
			.voxelSizeShift = voxelSizeShift,
			.voxelSizeMask = pos.voxelSize - 1,
			.widthShift = voxelSizeShift + chunkShift,
			.mutex = std.Thread.Mutex{},
		};
	}

	pub fn setChanged(self: *Chunk) void {
		self.wasChanged = true;
		{
			self.mutex.lock();
			if(self.wasCleaned) {
				self.save();
			}
			self.mutex.unlock();
		}
	}

	pub fn clean(self: *Chunk) void {
		{
			self.mutex.lock();
			self.wasCleaned = true;
			self.save();
			self.mutex.unlock();
		}
	}

	pub fn unclean(self: *Chunk) void {
		{
			self.mutex.lock();
			self.wasCleaned = false;
			self.save();
			self.mutex.unlock();
		}
	}

	/// Checks if the given relative coordinates lie within the bounds of this chunk.
	pub fn liesInChunk(self: *const Chunk, x: i32, y: i32, z: i32) bool {
		return x >= 0 and x < self.width
			and y >= 0 and y < self.width
			and z >= 0 and z < self.width;
	}

	/// This is useful to convert for loops to work for reduced resolution:
	/// Instead of using
	/// for(int x = start; x < end; x++)
	/// for(int x = chunk.startIndex(start); x < end; x += chunk.getVoxelSize())
	/// should be used to only activate those voxels that are used in Cubyz's downscaling technique.
	pub fn startIndex(self: *const Chunk, start: i32) i32 {
		return start+self.voxelSizeMask & ~self.voxelSizeMask; // Rounds up to the nearest valid voxel coordinate.
	}

	/// Updates a block if current value is air or the current block is degradable.
	/// Does not do any bound checks. They are expected to be done with the `liesInChunk` function.
	pub fn updateBlockIfDegradable(self: *Chunk, _x: i32, _y: i32, _z: i32, newBlock: Block) void {
		const x = _x >> self.voxelSizeShift;
		const y = _y >> self.voxelSizeShift;
		const z = _z >> self.voxelSizeShift;
		var index = getIndex(x, y, z);
		if (self.blocks[index].typ == 0 or self.blocks[index].degradable()) {
			self.blocks[index] = newBlock;
		}
	}

	/// Updates a block if it is inside this chunk.
	/// Does not do any bound checks. They are expected to be done with the `liesInChunk` function.
	pub fn updateBlock(self: *Chunk, _x: i32, _y: i32, _z: i32, newBlock: Block) void {
		const x = _x >> self.voxelSizeShift;
		const y = _y >> self.voxelSizeShift;
		const z = _z >> self.voxelSizeShift;
		var index = getIndex(x, y, z);
		self.blocks[index] = newBlock;
	}

	/// Updates a block if it is inside this chunk. Should be used in generation to prevent accidently storing these as changes.
	/// Does not do any bound checks. They are expected to be done with the `liesInChunk` function.
	pub fn updateBlockInGeneration(self: *Chunk, _x: i32, _y: i32, _z: i32, newBlock: Block) void {
		const x = _x >> self.voxelSizeShift;
		const y = _y >> self.voxelSizeShift;
		const z = _z >> self.voxelSizeShift;
		var index = getIndex(x, y, z);
		self.blocks[index] = newBlock;
	}

	/// Gets a block if it is inside this chunk.
	/// Does not do any bound checks. They are expected to be done with the `liesInChunk` function.
	pub fn getBlock(self: *const Chunk, _x: i32, _y: i32, _z: i32) Block {
		const x = _x >> self.voxelSizeShift;
		const y = _y >> self.voxelSizeShift;
		const z = _z >> self.voxelSizeShift;
		var index = getIndex(x, y, z);
		return self.blocks[index];
	}

	pub fn getNeighbors(self: *const Chunk, x: i32, y: i32, z: i32, neighborsArray: *[6]Block) void {
		std.debug.assert(neighborsArray.length == 6);
		x &= chunkMask;
		y &= chunkMask;
		z &= chunkMask;
		for(Neighbors.relX, 0..) |_, i| {
			var xi = x + Neighbors.relX[i];
			var yi = y + Neighbors.relY[i];
			var zi = z + Neighbors.relZ[i];
			if (xi == (xi & chunkMask) and yi == (yi & chunkMask) and zi == (zi & chunkMask)) { // Simple double-bound test for coordinates.
				neighborsArray[i] = self.getBlock(xi, yi, zi);
			} else {
				// TODO: What about other chunks?
//				NormalChunk ch = world.getChunk(xi + wx, yi + wy, zi + wz);
//				if (ch != null) {
//					neighborsArray[i] = ch.getBlock(xi & chunkMask, yi & chunkMask, zi & chunkMask);
//				} else {
//					neighborsArray[i] = 1; // Some solid replacement, in case the chunk isn't loaded. TODO: Properly choose a solid block.
//				}
			}
		}
	}

	pub fn updateFromLowerResolution(self: *Chunk, other: *const Chunk) void {
		const xOffset = if(other.wx != self.wx) chunkSize/2 else 0; // Offsets of the lower resolution chunk in this chunk.
		const yOffset = if(other.wy != self.wy) chunkSize/2 else 0;
		const zOffset = if(other.wz != self.wz) chunkSize/2 else 0;
		
		var x: i32 = 0;
		while(x < chunkSize/2): (x += 1) {
			var y: i32 = 0;
			while(y < chunkSize/2): (y += 1) {
				var z: i32 = 0;
				while(z < chunkSize/2): (z += 1) {
					// Count the neighbors for each subblock. An transparent block counts 5. A chunk border(unknown block) only counts 1.
					var neighborCount: [8]u32 = undefined;
					var octantBlocks: [8]Block = undefined;
					var maxCount: u32 = 0;
					var dx: i32 = 0;
					while(dx <= 1): (dx += 1) {
						var dy: i32 = 0;
						while(dy <= 1): (dy += 1) {
							var dz: i32 = 0;
							while(dz <= 1): (dz += 1) {
								const index = getIndex(x*2 + dx, y*2 + dy, z*2 + dz);
								const i = dx*4 + dz*2 + dy;
								octantBlocks[i] = other.blocks[index];
								if(octantBlocks[i] == 0) continue; // I don't care about air blocks.
								
								var count: u32 = 0;
								for(Neighbors.iterable) |n| {
									const nx = x*2 + dx + Neighbors.relX[n];
									const ny = y*2 + dy + Neighbors.relY[n];
									const nz = z*2 + dz + Neighbors.relZ[n];
									if((nx & chunkMask) == nx and (ny & chunkMask) == ny and (nz & chunkMask) == nz) { // If it's inside the chunk.
										const neighborIndex = getIndex(nx, ny, nz);
										if(other.blocks[neighborIndex].transparent()) {
											count += 5;
										}
									} else {
										count += 1;
									}
								}
								maxCount = @max(maxCount, count);
								neighborCount[i] = count;
							}
						}
					}
					// Uses a specific permutation here that keeps high resolution patterns in lower resolution.
					const permutationStart = (x & 1)*4 + (z & 1)*2 + (y & 1);
					const block = Block{.typ = 0, .data = 0};
					for(0..8) |i| {
						const appliedPermutation = permutationStart ^ i;
						if(neighborCount[appliedPermutation] >= maxCount - 1) { // Avoid pattern breaks at chunk borders.
							block = blocks[appliedPermutation];
						}
					}
					// Update the block:
					const thisIndex = getIndex(x + xOffset, y + yOffset, z + zOffset);
					self.blocks[thisIndex] = block;
				}
			}
		}
		
		self.setChanged();
	}

	pub fn save(self: *Chunk, world: *main.server.ServerWorld) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		if(self.wasChanged) {
//		TODO:	ChunkIO.storeChunkToFile(world, this);
			self.wasChanged = false;
			// Update the next lod chunk:
			if(self.pos.voxelSize != 1 << settings.highestLOD) {
				var pos = self.pos;
				pos.wx &= ~pos.voxelSize;
				pos.wy &= ~pos.voxelSize;
				pos.wz &= ~pos.voxelSize;
				pos.voxelSize *= 2;
				const nextHigherLod = world.chunkManager.getOrGenerateChunk(pos);
				nextHigherLod.updateFromLowerResolution(self);
			}
		}
	}

//	TODO: Check if/how they are needed:
//	
//	public Vector3d getMin() {
//		return new Vector3d(wx, wy, wz);
//	}
//	
//	public Vector3d getMax() {
//		return new Vector3d(wx + width, wy + width, wz + width);
//	}
};


pub const meshing = struct {
	var shader: Shader = undefined;
	var transparentShader: Shader = undefined;
	const UniformStruct = struct {
		projectionMatrix: c_int,
		viewMatrix: c_int,
		modelPosition: c_int,
		screenSize: c_int,
		ambientLight: c_int,
		@"fog.activ": c_int,
		@"fog.color": c_int,
		@"fog.density": c_int,
		texture_sampler: c_int,
		emissionSampler: c_int,
		@"waterFog.activ": c_int,
		@"waterFog.color": c_int,
		@"waterFog.density": c_int,
		time: c_int,
		visibilityMask: c_int,
		voxelSize: c_int,
		nearPlane: c_int,
	};
	pub var uniforms: UniformStruct = undefined;
	pub var transparentUniforms: UniformStruct = undefined;
	var vao: c_uint = undefined;
	var vbo: c_uint = undefined;
	var faces: std.ArrayList(u32) = undefined;
	pub var faceBuffer: graphics.LargeBuffer = undefined;
	pub var quadsDrawn: usize = 0;
	pub var transparentQuadsDrawn: usize = 0;

	pub fn init() !void {
		shader = try Shader.initAndGetUniforms("assets/cubyz/shaders/chunks/chunk_vertex.vs", "assets/cubyz/shaders/chunks/chunk_fragment.fs", &uniforms);
		transparentShader = try Shader.initAndGetUniforms("assets/cubyz/shaders/chunks/chunk_vertex.vs", "assets/cubyz/shaders/chunks/transparent_fragment.fs", &transparentUniforms);

		var rawData: [6*3 << (3*chunkShift)]u32 = undefined; // 6 vertices per face, maximum 3 faces/block
		const lut = [_]u32{0, 1, 2, 2, 1, 3};
		for(0..rawData.len) |i| {
			rawData[i] = @as(u32, @intCast(i))/6*4 + lut[i%6];
		}

		c.glGenVertexArrays(1, &vao);
		c.glBindVertexArray(vao);
		c.glGenBuffers(1, &vbo);
		c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, vbo);
		c.glBufferData(c.GL_ELEMENT_ARRAY_BUFFER, rawData.len*@sizeOf(u32), &rawData, c.GL_STATIC_DRAW);
		c.glBindVertexArray(0);

		faces = try std.ArrayList(u32).initCapacity(main.globalAllocator, 65536);
		try faceBuffer.init(main.globalAllocator, 512 << 20, 3);
	}

	pub fn deinit() void {
		shader.deinit();
		transparentShader.deinit();
		c.glDeleteVertexArrays(1, &vao);
		c.glDeleteBuffers(1, &vbo);
		faces.deinit();
		faceBuffer.deinit();
	}

	pub fn bindShaderAndUniforms(projMatrix: Mat4f, ambient: Vec3f, time: u32) void {
		shader.bind();

		c.glUniform1i(uniforms.@"fog.activ", if(game.fog.active) 1 else 0);
		c.glUniform3fv(uniforms.@"fog.color", 1, @ptrCast(&game.fog.color));
		c.glUniform1f(uniforms.@"fog.density", game.fog.density);

		c.glUniformMatrix4fv(uniforms.projectionMatrix, 1, c.GL_FALSE, @ptrCast(&projMatrix));

		c.glUniform1i(uniforms.texture_sampler, 0);
		c.glUniform1i(uniforms.emissionSampler, 1);

		c.glUniformMatrix4fv(uniforms.viewMatrix, 1, c.GL_FALSE, @ptrCast(&game.camera.viewMatrix));

		c.glUniform3f(uniforms.ambientLight, ambient[0], ambient[1], ambient[2]);

		c.glUniform1i(uniforms.time, @as(u31, @truncate(time)));

		c.glUniform1f(uniforms.nearPlane, renderer.zNear);

		c.glBindVertexArray(vao);
	}

	pub fn bindTransparentShaderAndUniforms(projMatrix: Mat4f, ambient: Vec3f, time: u32) void {
		transparentShader.bind();

		c.glUniform1i(transparentUniforms.@"fog.activ", if(game.fog.active) 1 else 0);
		c.glUniform3fv(transparentUniforms.@"fog.color", 1, @ptrCast(&game.fog.color));
		c.glUniform1f(transparentUniforms.@"fog.density", game.fog.density);

		c.glUniformMatrix4fv(transparentUniforms.projectionMatrix, 1, c.GL_FALSE, @ptrCast(&projMatrix));

		c.glUniform1i(transparentUniforms.texture_sampler, 0);
		c.glUniform1i(transparentUniforms.emissionSampler, 1);

		c.glUniformMatrix4fv(transparentUniforms.viewMatrix, 1, c.GL_FALSE, @ptrCast(&game.camera.viewMatrix));

		c.glUniform3f(transparentUniforms.ambientLight, ambient[0], ambient[1], ambient[2]);

		c.glUniform1i(transparentUniforms.time, @as(u31, @truncate(time)));

		c.glUniform1f(transparentUniforms.nearPlane, renderer.zNear);

		c.glBindVertexArray(vao);
	}

	pub const FaceData = extern struct {
		position: u32,
		blockAndModel: u32,
	};

	const PrimitiveMesh = struct {
		faces: std.ArrayList(FaceData),
		bufferAllocation: graphics.LargeBuffer.Allocation = .{.start = 0, .len = 0},
		coreCount: u31 = 0,
		neighborStart: [7]u31 = [_]u31{0} ** 7,
		vertexCount: u31 = 0,
		wasChanged: bool = false,

		fn deinit(self: *PrimitiveMesh) void {
			faceBuffer.free(self.bufferAllocation) catch unreachable;
			self.faces.deinit();
		}

		fn reset(self: *PrimitiveMesh) void {
			self.faces.clearRetainingCapacity();
		}

		fn resetToCore(self: *PrimitiveMesh) void {
			self.faces.shrinkRetainingCapacity(self.coreCount);
		}

		fn append(self: *PrimitiveMesh, face: FaceData) !void {
			try self.faces.append(face);
		}

		fn updateCore(self: *PrimitiveMesh) void {
			self.coreCount = @intCast(self.faces.items.len);
			self.neighborStart = [_]u31{self.coreCount} ** 7;
		}

		fn startNeighbor(self: *PrimitiveMesh, neighbor: usize) void {
			self.neighborStart[neighbor] = @intCast(self.faces.items.len);
		}

		fn replaceNeighbors(self: *PrimitiveMesh, neighbor: usize, additionalNeighborFaces: []FaceData) !void {
			var rangeStart = self.neighborStart[neighbor ^ 1];
			var rangeEnd = self.neighborStart[(neighbor ^ 1)+1];
			try self.faces.replaceRange(rangeStart, rangeEnd - rangeStart, additionalNeighborFaces);
			for(self.neighborStart[1+(neighbor ^ 1)..]) |*neighborStart| {
				neighborStart.* = neighborStart.* - (rangeEnd - rangeStart) + @as(u31, @intCast(additionalNeighborFaces.len));
			}
			try self.uploadData();
		}

		fn finish(self: *PrimitiveMesh) !void {
			self.neighborStart[6] = @intCast(self.faces.items.len);
			try self.uploadData();
		}

		fn uploadData(self: *PrimitiveMesh) !void {
			self.vertexCount = @intCast(6*self.faces.items.len);
			try faceBuffer.realloc(&self.bufferAllocation, @intCast(8*self.faces.items.len));
			faceBuffer.bufferSubData(self.bufferAllocation.start, FaceData, self.faces.items);
			self.wasChanged = true;
		}

		fn addFace(self: *PrimitiveMesh, faceData: FaceData, fromNeighborChunk: ?u3) !void {
			var insertionIndex: u31 = undefined;
			if(fromNeighborChunk) |neighbor| {
				insertionIndex = self.neighborStart[neighbor];
				for(self.neighborStart[neighbor+1..]) |*start| {
					start.* += 1;
				}
			} else {
				insertionIndex = self.coreCount;
				self.coreCount += 1;
				for(&self.neighborStart) |*start| {
					start.* += 1;
				}
			}
			try self.faces.insert(insertionIndex, faceData);
		}

		fn removeFace(self: *PrimitiveMesh, faceData: FaceData, fromNeighborChunk: ?u3) void {
			var searchStart: u32 = undefined;
			var searchEnd: u32 = undefined;
			if(fromNeighborChunk) |neighbor| {
				searchStart = self.neighborStart[neighbor];
				searchEnd = self.neighborStart[neighbor+1];
				for(self.neighborStart[neighbor+1..]) |*start| {
					start.* -= 1;
				}
			} else {
				searchStart = 0;
				searchEnd = self.coreCount;
				self.coreCount -= 1;
				for(&self.neighborStart) |*start| {
					start.* -= 1;
				}
			}
			for(searchStart..searchEnd) |i| {
				if(std.meta.eql(self.faces.items[i], faceData)) {
					_ = self.faces.orderedRemove(i);
					return;
				}
			}
			@panic("Couldn't find the face to remove. This case is not handled.");
		}

		fn changeFace(self: *PrimitiveMesh, oldFaceData: FaceData, newFaceData: FaceData, fromNeighborChunk: ?u3) void {
			var searchRange: []FaceData = undefined;
			if(fromNeighborChunk) |neighbor| {
				searchRange = self.faces.items[self.neighborStart[neighbor]..self.neighborStart[neighbor+1]];
			} else {
				searchRange = self.faces.items[0..self.coreCount];
			}
			var i: u32 = 0;
			while(i < searchRange.len): (i += 2) {
				if(std.meta.eql(self.faces.items[i], oldFaceData)) {
					searchRange[i] = newFaceData;
					return;
				}
			}
			@panic("Couldn't find the face to replace.");
		}
	};

	pub const ChunkMesh = struct {
		const SortingData = struct {
			index: u32,
			distance: u32,
			isBackFace: bool,

			pub fn update(self: *SortingData, face: FaceData, chunkDx: i32, chunkDy: i32, chunkDz: i32) void {
				const x: i32 = @intCast(face.position & 31);
				const y: i32 = @intCast(face.position >> 5 & 31);
				const z: i32 = @intCast(face.position >> 10 & 31);
				const dx = x + chunkDx;
				const dy = y + chunkDy;
				const dz = z + chunkDz;
				const normal = face.position >> 20 & 7;
				switch(Neighbors.vectorComponent[normal]) {
					.x => {
						self.isBackFace = (dx < 0) == (Neighbors.relX[normal] < 0);
						if(dx == 0) {
							self.isBackFace = false;
						}
					},
					.y => {
						self.isBackFace = (dy < 0) == (Neighbors.relY[normal] < 0);
						if(dy == 0) {
							self.isBackFace = false;
						}
					},
					.z => {
						self.isBackFace = (dz < 0) == (Neighbors.relZ[normal] < 0);
						if(dz == 0) {
							self.isBackFace = false;
						}
					},
				}
				const fullDx = dx - Neighbors.relX[normal];
				const fullDy = dy - Neighbors.relY[normal];
				const fullDz = dz - Neighbors.relZ[normal];
				self.distance = std.math.absCast(fullDx) + std.math.absCast(fullDy) + std.math.absCast(fullDz);
			}
		};
		const BoundingRectToNeighborChunk = struct {
			min: Vec3i = @splat(std.math.maxInt(i32)),
			max: Vec3i = @splat(0),

			fn adjustToBlock(self: *BoundingRectToNeighborChunk, block: Block, pos: Vec3i, neighbor: u3) void {
				if(block.viewThrough()) {
					self.min = @min(self.min, pos);
					self.max = @max(self.max, pos + Neighbors.orthogonalComponents[neighbor]);
				}
			}
		};
		pos: ChunkPosition,
		size: i32,
		chunk: std.atomic.Atomic(?*Chunk),
		opaqueMesh: PrimitiveMesh,
		transparentMesh: PrimitiveMesh,
		generated: bool = false,
		mutex: std.Thread.Mutex = std.Thread.Mutex{},
		visibilityMask: u8 = 0xff,
		transparentVao: c_uint = 0,
		transparentVbo: c_uint = 0,
		currentSorting: []SortingData = &.{},
		currentSortingSwap: []SortingData = &.{},
		lastTransparentUpdatePos: Vec3i = Vec3i{0, 0, 0},

		chunkBorders: [6]BoundingRectToNeighborChunk = [1]BoundingRectToNeighborChunk{.{}} ** 6,

		pub fn init(allocator: Allocator, pos: ChunkPosition) ChunkMesh {
			return ChunkMesh{
				.pos = pos,
				.size = chunkSize*pos.voxelSize,
				.opaqueMesh = .{
					.faces = std.ArrayList(FaceData).init(allocator)
				},
				.transparentMesh = .{
					.faces = std.ArrayList(FaceData).init(allocator)
				},
				.chunk = std.atomic.Atomic(?*Chunk).init(null),
			};
		}

		pub fn deinit(self: *ChunkMesh) void {
			self.opaqueMesh.deinit();
			self.transparentMesh.deinit();
			if(self.transparentVao != 0) {
				c.glDeleteVertexArrays(1, &self.transparentVao);
				c.glDeleteBuffers(1, &self.transparentVbo);
			}
			main.globalAllocator.free(self.currentSorting);
			main.globalAllocator.free(self.currentSortingSwap);
			if(self.chunk.load(.Monotonic)) |ch| {
				main.globalAllocator.destroy(ch);
			}
		}

		pub fn isEmpty(self: *const ChunkMesh) bool {
			return self.opaqueMesh.vertexCount == 0 and self.transparentMesh.vertexCount == 0;
		}

		fn canBeSeenThroughOtherBlock(block: Block, other: Block, neighbor: u3) bool {
			const rotatedModel = blocks.meshes.model(block);
			const model = &models.voxelModels.items[rotatedModel.modelIndex];
			const freestandingModel = rotatedModel.modelIndex != models.fullCube and switch(rotatedModel.permutation.permuteNeighborIndex(neighbor)) {
				Neighbors.dirNegX => model.min[0] != 0,
				Neighbors.dirPosX => model.max[0] != 16,
				Neighbors.dirDown => model.min[1] != 0,
				Neighbors.dirUp => model.max[1] != 16,
				Neighbors.dirNegZ => model.min[2] != 0,
				Neighbors.dirPosZ => model.max[2] != 16,
				else => unreachable,
			};
			return block.typ != 0 and (
				freestandingModel
				or other.typ == 0
				or (!std.meta.eql(block, other) and other.viewThrough())
				or blocks.meshes.model(other).modelIndex != 0 // TODO: make this more strict to avoid overdraw.
			);
		}

		pub fn regenerateMainMesh(self: *ChunkMesh, chunk: *Chunk) !void {
			std.debug.assert(!self.mutex.tryLock()); // The mutex should be locked when calling this function.
			self.opaqueMesh.reset();
			self.transparentMesh.reset();
			var n: u32 = 0;
			var x: u8 = 0;
			while(x < chunkSize): (x += 1) {
				var y: u8 = 0;
				while(y < chunkSize): (y += 1) {
					var z: u8 = 0;
					while(z < chunkSize): (z += 1) {
						const block = (&chunk.blocks)[getIndex(x, y, z)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
						if(block.typ == 0) continue;
						// Check all neighbors:
						for(Neighbors.iterable) |i| {
							n += 1;
							const x2 = x + Neighbors.relX[i];
							const y2 = y + Neighbors.relY[i];
							const z2 = z + Neighbors.relZ[i];
							if(x2&chunkMask != x2 or y2&chunkMask != y2 or z2&chunkMask != z2) continue; // Neighbor is outside the chunk.
							const neighborBlock = (&chunk.blocks)[getIndex(x2, y2, z2)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
							if(canBeSeenThroughOtherBlock(block, neighborBlock, i)) {
								if(block.transparent()) {
									if(block.hasBackFace()) {
										try self.transparentMesh.append(constructFaceData(block, i ^ 1, x, y, z, true));
									}
									try self.transparentMesh.append(constructFaceData(block, i, @intCast(x2), @intCast(y2), @intCast(z2), false));
								} else {
									try self.opaqueMesh.append(constructFaceData(block, i, @intCast(x2), @intCast(y2), @intCast(z2), false));
								}
							}
						}
					}
				}
			}
			// Check out the borders:
			x = 0;
			while(x < chunkSize): (x += 1) {
				var y: u8 = 0;
				while(y < chunkSize): (y += 1) {
					self.chunkBorders[Neighbors.dirNegX].adjustToBlock((&chunk.blocks)[getIndex(0, x, y)], .{0, x, y}, Neighbors.dirNegX); // TODO: Wait for the compiler bug to get fixed.
					self.chunkBorders[Neighbors.dirPosX].adjustToBlock((&chunk.blocks)[getIndex(chunkSize-1, x, y)], .{chunkSize, x, y}, Neighbors.dirPosX); // TODO: Wait for the compiler bug to get fixed.
					self.chunkBorders[Neighbors.dirDown].adjustToBlock((&chunk.blocks)[getIndex(x, 0, y)], .{x, 0, y}, Neighbors.dirDown); // TODO: Wait for the compiler bug to get fixed.
					self.chunkBorders[Neighbors.dirUp].adjustToBlock((&chunk.blocks)[getIndex(x, chunkSize-1, y)], .{x, chunkSize, y}, Neighbors.dirUp); // TODO: Wait for the compiler bug to get fixed.
					self.chunkBorders[Neighbors.dirNegZ].adjustToBlock((&chunk.blocks)[getIndex(x, y, 0)], .{x, y, 0}, Neighbors.dirNegZ); // TODO: Wait for the compiler bug to get fixed.
					self.chunkBorders[Neighbors.dirPosZ].adjustToBlock((&chunk.blocks)[getIndex(x, y, chunkSize-1)], .{x, y, chunkSize}, Neighbors.dirPosZ); // TODO: Wait for the compiler bug to get fixed.
				}
			}

			if(self.chunk.swap(chunk, .Monotonic)) |oldChunk| {
				main.globalAllocator.destroy(oldChunk);
			}
			self.transparentMesh.updateCore();
			self.opaqueMesh.updateCore();
		}

		fn addFace(self: *ChunkMesh, faceData: FaceData, fromNeighborChunk: ?u3, transparent: bool) !void {
			std.debug.assert(!self.mutex.tryLock()); // The mutex should be locked when calling this function.
			if(transparent) {
				try self.transparentMesh.addFace(faceData, fromNeighborChunk);
			} else {
				try self.opaqueMesh.addFace(faceData, fromNeighborChunk);
			}
		}

		fn removeFace(self: *ChunkMesh, faceData: FaceData, fromNeighborChunk: ?u3, transparent: bool) void {
			std.debug.assert(!self.mutex.tryLock()); // The mutex should be locked when calling this function.
			if(transparent) {
				self.transparentMesh.removeFace(faceData, fromNeighborChunk);
			} else {
				self.opaqueMesh.removeFace(faceData, fromNeighborChunk);
			}
		}

		fn changeFace(self: *ChunkMesh, oldFaceData: FaceData, newFaceData: FaceData, fromNeighborChunk: ?u3, oldTransparent: bool, newTransparent: bool) !void {
			std.debug.assert(!self.mutex.tryLock()); // The mutex should be locked when calling this function.
			if(oldTransparent) {
				if(newTransparent) {
					self.transparentMesh.changeFace(oldFaceData, newFaceData, fromNeighborChunk);
				} else {
					self.transparentMesh.removeFace(oldFaceData, fromNeighborChunk);
					try self.opaqueMesh.addFace(newFaceData, fromNeighborChunk);
				}
			} else {
				if(newTransparent) {
					self.opaqueMesh.removeFace(oldFaceData, fromNeighborChunk);
					try self.transparentMesh.addFace(newFaceData, fromNeighborChunk);
				} else {
					self.opaqueMesh.changeFace(oldFaceData, newFaceData, fromNeighborChunk);
				}
			}
		}

		pub fn updateBlock(self: *ChunkMesh, _x: i32, _y: i32, _z: i32, newBlock: Block) !void {
			const x = _x & chunkMask;
			const y = _y & chunkMask;
			const z = _z & chunkMask;
			self.mutex.lock();
			defer self.mutex.unlock();
			if(!self.generated) return;
			const oldBlock = self.chunk.load(.Monotonic).?.blocks[getIndex(x, y, z)];
			for(Neighbors.iterable) |neighbor| {
				var neighborMesh = self;
				var nx = x + Neighbors.relX[neighbor];
				var ny = y + Neighbors.relY[neighbor];
				var nz = z + Neighbors.relZ[neighbor];
				if(nx & chunkMask != nx or ny & chunkMask != ny or nz & chunkMask != nz) { // Outside this chunk.
					neighborMesh = renderer.RenderStructure.getNeighbor(self.pos, self.pos.voxelSize, neighbor) orelse continue;
					if(!neighborMesh.generated) continue;
					neighborMesh.mutex.lock();
				}
				defer if(neighborMesh != self) neighborMesh.mutex.unlock();
				nx &= chunkMask;
				ny &= chunkMask;
				nz &= chunkMask;
				const neighborBlock = neighborMesh.chunk.load(.Monotonic).?.blocks[getIndex(nx, ny, nz)];
				{ // TODO: Update blocks with transparent backfaces correctly.
					{ // The face of the changed block
						const newVisibility = canBeSeenThroughOtherBlock(newBlock, neighborBlock, neighbor);
						const newFaceData = constructFaceData(newBlock, neighbor, @intCast(nx), @intCast(ny), @intCast(nz), false);
						const oldFaceData = constructFaceData(oldBlock, neighbor, @intCast(nx), @intCast(ny), @intCast(nz), false);
						if(canBeSeenThroughOtherBlock(oldBlock, neighborBlock, neighbor) != newVisibility) {
							if(newVisibility) { // Adding the face
								if(neighborMesh == self) {
									try self.addFace(newFaceData, null, newBlock.transparent());
								} else {
									try neighborMesh.addFace(newFaceData, neighbor ^ 1, newBlock.transparent());
								}
							} else { // Removing the face
								if(neighborMesh == self) {
									self.removeFace(oldFaceData, null, oldBlock.transparent());
								} else {
									neighborMesh.removeFace(oldFaceData, neighbor ^ 1, oldBlock.transparent());
								}
							}
						} else if(newVisibility) { // Changing the face
							if(neighborMesh == self) {
								try self.changeFace(oldFaceData, newFaceData, null, oldBlock.transparent(), newBlock.transparent());
							} else {
								try neighborMesh.changeFace(oldFaceData, newFaceData, neighbor ^ 1, oldBlock.transparent(), newBlock.transparent());
							}
						}
					}
					{ // The face of the neighbor block
						const newVisibility = canBeSeenThroughOtherBlock(neighborBlock, newBlock, neighbor ^ 1);
						const newFaceData = constructFaceData(neighborBlock, neighbor ^ 1, @intCast(x), @intCast(y), @intCast(z), false);
						const oldFaceData = constructFaceData(neighborBlock, neighbor ^ 1, @intCast(x), @intCast(y), @intCast(z), false);
						if(canBeSeenThroughOtherBlock(neighborBlock, oldBlock, neighbor ^ 1) != newVisibility) {
							if(newVisibility) { // Adding the face
								if(neighborMesh == self) {
									try self.addFace(newFaceData, null, neighborBlock.transparent());
								} else {
									try self.addFace(newFaceData, neighbor, neighborBlock.transparent());
								}
							} else { // Removing the face
								if(neighborMesh == self) {
									self.removeFace(oldFaceData, null, neighborBlock.transparent());
								} else {
									self.removeFace(oldFaceData, neighbor, neighborBlock.transparent());
								}
							}
						}
					}
				}
				if(neighborMesh != self) {
					try neighborMesh.opaqueMesh.uploadData();
					try neighborMesh.transparentMesh.uploadData();
				}
			}
			self.chunk.load(.Monotonic).?.blocks[getIndex(x, y, z)] = newBlock;
			try self.opaqueMesh.uploadData();
			try self.transparentMesh.uploadData();
		}

		pub inline fn constructFaceData(block: Block, normal: u32, x: u32, y: u32, z: u32, comptime backFace: bool) FaceData {
			const model = blocks.meshes.model(block);
			return FaceData {
				.position = @as(u32, x) | @as(u32, y)<<5 | @as(u32, z)<<10 | normal<<20 | @as(u32, model.permutation.toInt())<<23 | (if(backFace) 1 << 19 else 0),
				.blockAndModel = block.typ | @as(u32, model.modelIndex)<<16,
			};
		}

		pub fn uploadDataAndFinishNeighbors(self: *ChunkMesh) !void { // TODO: The way neighboring chunks are handled doesn't work well with transparency.
			std.debug.assert(!self.mutex.tryLock()); // The mutex should be locked when calling this function.
			const chunk = self.chunk.load(.Monotonic) orelse return; // In the mean-time the mesh was discarded and recreated and all the data was lost.
			self.opaqueMesh.resetToCore();
			self.transparentMesh.resetToCore();
			for(Neighbors.iterable) |neighbor| {
				self.opaqueMesh.startNeighbor(neighbor);
				self.transparentMesh.startNeighbor(neighbor);
				var nullNeighborMesh = renderer.RenderStructure.getNeighbor(self.pos, self.pos.voxelSize, neighbor);
				if(nullNeighborMesh) |neighborMesh| {
					std.debug.assert(neighborMesh != self);
					neighborMesh.mutex.lock();
					defer neighborMesh.mutex.unlock();
					if(neighborMesh.generated) {
						var additionalNeighborFacesOpaque = std.ArrayList(FaceData).init(main.threadAllocator);
						defer additionalNeighborFacesOpaque.deinit();
						var additionalNeighborFacesTransparent = std.ArrayList(FaceData).init(main.threadAllocator);
						defer additionalNeighborFacesTransparent.deinit();
						var x3: u8 = if(neighbor & 1 == 0) @intCast(chunkMask) else 0;
						var x1: u8 = 0;
						while(x1 < chunkSize): (x1 += 1) {
							var x2: u8 = 0;
							while(x2 < chunkSize): (x2 += 1) {
								var x: u8 = undefined;
								var y: u8 = undefined;
								var z: u8 = undefined;
								if(Neighbors.relX[neighbor] != 0) {
									x = x3;
									y = x1;
									z = x2;
								} else if(Neighbors.relY[neighbor] != 0) {
									x = x1;
									y = x3;
									z = x2;
								} else {
									x = x2;
									y = x1;
									z = x3;
								}
								var otherX: u8 = @intCast(x+%Neighbors.relX[neighbor] & chunkMask);
								var otherY: u8 = @intCast(y+%Neighbors.relY[neighbor] & chunkMask);
								var otherZ: u8 = @intCast(z+%Neighbors.relZ[neighbor] & chunkMask);
								var block = (&chunk.blocks)[getIndex(x, y, z)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
								var otherBlock = (&neighborMesh.chunk.load(.Monotonic).?.blocks)[getIndex(otherX, otherY, otherZ)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
								if(canBeSeenThroughOtherBlock(block, otherBlock, neighbor)) {
									if(block.transparent()) {
										if(block.hasBackFace()) {
											try self.transparentMesh.append(constructFaceData(block, neighbor ^ 1, x, y, z, true));
										}
										try additionalNeighborFacesTransparent.append(constructFaceData(block, neighbor, otherX, otherY, otherZ, false));
									} else {
										try additionalNeighborFacesOpaque.append(constructFaceData(block, neighbor, otherX, otherY, otherZ, false));
									}
								}
								if(canBeSeenThroughOtherBlock(otherBlock, block, neighbor ^ 1)) {
									if(otherBlock.transparent()) {
										if(otherBlock.hasBackFace()) {
											try additionalNeighborFacesTransparent.append(constructFaceData(otherBlock, neighbor, otherX, otherY, otherZ, true));
										}
										try self.transparentMesh.append(constructFaceData(otherBlock, neighbor ^ 1, x, y, z, false));
									} else {
										try self.opaqueMesh.append(constructFaceData(otherBlock, neighbor ^ 1, x, y, z, false));
									}
								}
							}
						}
						try neighborMesh.opaqueMesh.replaceNeighbors(neighbor, additionalNeighborFacesOpaque.items);
						try neighborMesh.transparentMesh.replaceNeighbors(neighbor, additionalNeighborFacesTransparent.items);
						continue;
					}
				}
				// lod border:
				if(self.pos.voxelSize == 1 << settings.highestLOD) continue;
				var neighborMesh = renderer.RenderStructure.getNeighbor(self.pos, 2*self.pos.voxelSize, neighbor) orelse return error.LODMissing;
				neighborMesh.mutex.lock();
				defer neighborMesh.mutex.unlock();
				if(neighborMesh.generated) {
					const x3: u8 = if(neighbor & 1 == 0) @intCast(chunkMask) else 0;
					const offsetX = @divExact(self.pos.wx, self.pos.voxelSize) & chunkSize;
					const offsetY = @divExact(self.pos.wy, self.pos.voxelSize) & chunkSize;
					const offsetZ = @divExact(self.pos.wz, self.pos.voxelSize) & chunkSize;
					var x1: u8 = 0;
					while(x1 < chunkSize): (x1 += 1) {
						var x2: u8 = 0;
						while(x2 < chunkSize): (x2 += 1) {
							var x: u8 = undefined;
							var y: u8 = undefined;
							var z: u8 = undefined;
							if(Neighbors.relX[neighbor] != 0) {
								x = x3;
								y = x1;
								z = x2;
							} else if(Neighbors.relY[neighbor] != 0) {
								x = x1;
								y = x3;
								z = x2;
							} else {
								x = x2;
								y = x1;
								z = x3;
							}
							var otherX: u8 = @intCast((x+%Neighbors.relX[neighbor]+%offsetX >> 1) & chunkMask);
							var otherY: u8 = @intCast((y+%Neighbors.relY[neighbor]+%offsetY >> 1) & chunkMask);
							var otherZ: u8 = @intCast((z+%Neighbors.relZ[neighbor]+%offsetZ >> 1) & chunkMask);
							var block = (&chunk.blocks)[getIndex(x, y, z)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
							var otherBlock = (&neighborMesh.chunk.load(.Monotonic).?.blocks)[getIndex(otherX, otherY, otherZ)]; // ← a temporary fix to a compiler performance bug. TODO: check if this was fixed.
							if(canBeSeenThroughOtherBlock(otherBlock, block, neighbor ^ 1)) {
								if(otherBlock.transparent()) {
									try self.transparentMesh.append(constructFaceData(otherBlock, neighbor ^ 1, x, y, z, false));
								} else {
									try self.opaqueMesh.append(constructFaceData(otherBlock, neighbor ^ 1, x, y, z, false));
								}
							}
							if(block.hasBackFace()) {
								if(canBeSeenThroughOtherBlock(block, otherBlock, neighbor)) {
									try self.transparentMesh.append(constructFaceData(block, neighbor ^ 1, x, y, z, true));
								}
							}
						}
					}
				} else {
					return error.LODMissing;
				}
			}
			try self.opaqueMesh.finish();
			try self.transparentMesh.finish();
			self.generated = true;
		}

		pub fn render(self: *ChunkMesh, playerPosition: Vec3d) void {
			if(!self.generated) {
				return;
			}
			if(self.opaqueMesh.vertexCount == 0) return;
			c.glUniform3f(
				uniforms.modelPosition,
				@floatCast(@as(f64, @floatFromInt(self.pos.wx)) - playerPosition[0]),
				@floatCast(@as(f64, @floatFromInt(self.pos.wy)) - playerPosition[1]),
				@floatCast(@as(f64, @floatFromInt(self.pos.wz)) - playerPosition[2])
			);
			c.glUniform1i(uniforms.visibilityMask, self.visibilityMask);
			c.glUniform1i(uniforms.voxelSize, self.pos.voxelSize);
			quadsDrawn += self.opaqueMesh.faces.items.len;
			c.glDrawElementsBaseVertex(c.GL_TRIANGLES, self.opaqueMesh.vertexCount, c.GL_UNSIGNED_INT, null, self.opaqueMesh.bufferAllocation.start/8*4);
		}

		pub fn renderTransparent(self: *ChunkMesh, playerPosition: Vec3d) !void {
			if(!self.generated) {
				return;
			}
			if(self.transparentMesh.vertexCount == 0) return;
			if(self.transparentVao == 0) {
				c.glGenVertexArrays(1, &self.transparentVao);
				c.glBindVertexArray(self.transparentVao);
				c.glGenBuffers(1, &self.transparentVbo);
				c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, self.transparentVbo);
			} else {
				c.glBindVertexArray(self.transparentVao);
			}

			var needsUpdate: bool = false;
			if(self.transparentMesh.wasChanged) {
				self.currentSorting = try main.globalAllocator.realloc(self.currentSorting, self.transparentMesh.faces.items.len);
				self.currentSortingSwap = try main.globalAllocator.realloc(self.currentSortingSwap, self.transparentMesh.faces.items.len);

				for(self.currentSorting, 0..) |*val, i| {
					val.index = @intCast(i);
				}
				needsUpdate = true;
			}

			var relativePos = Vec3d {
				@as(f64, @floatFromInt(self.pos.wx)) - playerPosition[0],
				@as(f64, @floatFromInt(self.pos.wy)) - playerPosition[1],
				@as(f64, @floatFromInt(self.pos.wz)) - playerPosition[2]
			}/@as(Vec3d, @splat(@as(f64, @floatFromInt(self.pos.voxelSize))));
			relativePos = @min(relativePos, @as(Vec3d, @splat(0)));
			relativePos = @max(relativePos, @as(Vec3d, @splat(-32)));
			var updatePos = vec.intFromFloat(i32, relativePos);
			if(@reduce(.Or, updatePos != self.lastTransparentUpdatePos)) {
				self.lastTransparentUpdatePos = updatePos;
				needsUpdate = true;
			}
			if(needsUpdate) {
				var transparencyData: [][6]u32 = try main.threadAllocator.alloc([6]u32, self.currentSorting.len);
				defer main.threadAllocator.free(transparencyData);
				// TODO: Could additionally filter back-faces to reduce work on the gpu side.

				for(self.currentSorting) |*val| {
					val.update(
						self.transparentMesh.faces.items[val.index],
						updatePos[0],
						updatePos[1],
						updatePos[2],
					);
				}

				// Sort by back vs front face:
				{
					var backFaceStart: usize = 0;
					for(self.currentSorting) |*val| {
						if(val.isBackFace) {
							std.mem.swap(@TypeOf(val.*), val, &self.currentSorting[backFaceStart]);
							backFaceStart += 1;
						}
					}
				}

				// Sort it using bucket sort:
				var buckets: [34*3]u32 = undefined;
				@memset(&buckets, 0);
				for(self.currentSorting) |val| {
					buckets[34*3 - 1 - val.distance] += 1;
				}
				var prefixSum: u32 = 0;
				for(&buckets) |*val| {
					const copy = val.*;
					val.* = prefixSum;
					prefixSum += copy;
				}
				// Move it over into a new buffer:
				for(0..self.currentSorting.len) |i| {
					const bucket = 34*3 - 1 - self.currentSorting[i].distance;
					self.currentSortingSwap[buckets[bucket]] = self.currentSorting[i];
					buckets[bucket] += 1;
				}

				const swap = self.currentSorting;
				self.currentSorting = self.currentSortingSwap;
				self.currentSortingSwap = swap;

				// Fill the data:
				for(transparencyData, 0..) |*face, i| {
					const lut = [_]u32{0, 1, 2, 2, 1, 3};
					const index = self.currentSorting[i].index*4;
					inline for(face, 0..) |*val, vertex| {
						val.* = index + lut[vertex];
					}
				}

				// Upload:
				c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, self.transparentVbo);
				c.glBufferData(c.GL_ELEMENT_ARRAY_BUFFER, @intCast(transparencyData.len*@sizeOf([6]u32)), transparencyData.ptr, c.GL_DYNAMIC_DRAW);
			}

			c.glUniform3f(
				transparentUniforms.modelPosition,
				@floatCast(@as(f64, @floatFromInt(self.pos.wx)) - playerPosition[0]),
				@floatCast(@as(f64, @floatFromInt(self.pos.wy)) - playerPosition[1]),
				@floatCast(@as(f64, @floatFromInt(self.pos.wz)) - playerPosition[2])
			);
			c.glUniform1i(transparentUniforms.visibilityMask, self.visibilityMask);
			c.glUniform1i(transparentUniforms.voxelSize, self.pos.voxelSize);
			transparentQuadsDrawn += self.transparentMesh.faces.items.len;
			c.glDrawElementsBaseVertex(c.GL_TRIANGLES, self.transparentMesh.vertexCount, c.GL_UNSIGNED_INT, null, self.transparentMesh.bufferAllocation.start/8*4);
		}
	};
};