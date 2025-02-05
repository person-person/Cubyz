const std = @import("std");

const assets = @import("assets.zig");
const chunk = @import("chunk.zig");
const itemdrop = @import("itemdrop.zig");
const ClientItemDropManager = itemdrop.ClientItemDropManager;
const items = @import("items.zig");
const Inventory = items.Inventory;
const JsonElement = @import("json.zig").JsonElement;
const main = @import("main.zig");
const KeyBoard = main.KeyBoard;
const network = @import("network.zig");
const Connection = network.Connection;
const ConnectionManager = network.ConnectionManager;
const vec = @import("vec.zig");
const Vec3f = vec.Vec3f;
const Vec4f = vec.Vec4f;
const Vec3d = vec.Vec3d;
const Mat4f = vec.Mat4f;
const graphics = @import("graphics.zig");
const Fog = graphics.Fog;
const renderer = @import("renderer.zig");
const settings = @import("settings.zig");

pub const camera = struct {
	pub var rotation: Vec3f = Vec3f{0, 0, 0};
	pub var direction: Vec3f = Vec3f{0, 0, 0};
	pub var viewMatrix: Mat4f = Mat4f.identity();
	pub fn moveRotation(mouseX: f32, mouseY: f32) void {
		// Mouse movement along the x-axis rotates the image along the y-axis.
		rotation[0] += mouseY;
		if(rotation[0] > std.math.pi/2.0) {
			rotation[0] = std.math.pi/2.0;
		} else if(rotation[0] < -std.math.pi/2.0) {
			rotation[0] = -std.math.pi/2.0;
		}
		// Mouse movement along the y-axis rotates the image along the x-axis.
		rotation[1] += mouseX;
	}

	pub fn updateViewMatrix() void {
		direction = vec.rotateY(vec.rotateX(Vec3f{0, 0, -1}, -rotation[0]), -rotation[1]);
		viewMatrix = Mat4f.rotationX(rotation[0]).mul(Mat4f.rotationY(rotation[1]));
	}
};

pub const Player = struct {
	pub var super: main.server.Entity = .{};
	pub var id: u32 = 0;
	pub var isFlying: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(true);
	pub var mutex: std.Thread.Mutex = std.Thread.Mutex{};
	pub var inventory__SEND_CHANGES_TO_SERVER: Inventory = undefined;
	pub var selectedSlot: u32 = 0;

	pub var maxHealth: f32 = 8;
	pub var health: f32 = 4.5;

	fn loadFrom(json: JsonElement) !void {
		super.loadFrom(json);
		try inventory__SEND_CHANGES_TO_SERVER.loadFromJson(json.getChild("inventory"));
	}

	pub fn setPosBlocking(newPos: Vec3d) void {
		mutex.lock();
		defer mutex.unlock();
		super.pos = newPos;
	}

	pub fn getPosBlocking() Vec3d {
		mutex.lock();
		defer mutex.unlock();
		return super.pos;
	}

	pub fn getVelBlocking() Vec3d {
		mutex.lock();
		defer mutex.unlock();
		return super.vel;
	}

	pub fn placeBlock() void {
		main.renderer.MeshSelection.placeBlock(&inventory__SEND_CHANGES_TO_SERVER.items[selectedSlot]) catch |err| {
			std.log.err("Error while placing block: {s}", .{@errorName(err)});
		};
	}
};

pub const World = struct {
	const dayCycle: u63 = 12000; // Length of one in-game day in 100ms. Midnight is at DAY_CYCLE/2. Sunrise and sunset each take about 1/16 of the day. Currently set to 20 minutes

	conn: *Connection,
	manager: *ConnectionManager,
	ambientLight: f32 = 0,
	clearColor: Vec4f = Vec4f{0, 0, 0, 1},
	gravity: f64 = 9.81*1.5, // TODO: Balance
	name: []const u8,
	milliTime: i64,
	gameTime: std.atomic.Atomic(i64) = std.atomic.Atomic(i64).init(0),
	spawn: Vec3f = undefined,
	blockPalette: *assets.BlockPalette = undefined,
	itemDrops: ClientItemDropManager = undefined,
	playerBiome: *const main.server.terrain.biomes.Biome = undefined,
	
//	public final ArrayList<String> chatHistory = new ArrayList<>();

	pub fn init(self: *World, ip: []const u8, manager: *ConnectionManager) !void {
		self.* = .{
			.conn = try Connection.init(manager, ip),
			.manager = manager,
			.name = "client",
			.milliTime = std.time.milliTimestamp(),
		};
		try self.itemDrops.init(main.globalAllocator, self);
		Player.inventory__SEND_CHANGES_TO_SERVER = try Inventory.init(main.globalAllocator, 32);
		// TODO:
//		player = new ClientPlayer(this, 0);
		try network.Protocols.handShake.clientSide(self.conn, settings.playerName);

		main.Window.setMouseGrabbed(true);

		try main.blocks.meshes.generateTextureArray();
		self.playerBiome = main.server.terrain.biomes.getById("");
	}

	pub fn deinit(self: *World) void {
		// TODO: Close all world related guis.
		self.conn.deinit();
		self.itemDrops.deinit();
		self.blockPalette.deinit();
		Player.inventory__SEND_CHANGES_TO_SERVER.deinit(main.globalAllocator);
		self.manager.deinit();
		assets.unloadAssets();
		main.server.stop();
		main.threadPool.clear();
		if(main.server.thread) |serverThread| {
			serverThread.join();
			main.server.thread = null;
		}
	}

	pub fn finishHandshake(self: *World, json: JsonElement) !void {
		// TODO: Consider using a per-world allocator.
		self.blockPalette = try assets.BlockPalette.init(main.globalAllocator, json.getChild("blockPalette"));
		var jsonSpawn = json.getChild("spawn");
		self.spawn[0] = jsonSpawn.get(f32, "x", 0);
		self.spawn[1] = jsonSpawn.get(f32, "y", 0);
		self.spawn[2] = jsonSpawn.get(f32, "z", 0);

		// TODO:
//		if(Server.world != null) {
//			// Share the registries of the local server:
//			registries = Server.world.getCurrentRegistries();
//		} else {
//			registries = new CurrentWorldRegistries(this, "serverAssets/", blockPalette);
//		}
//
//		// Call mods for this new world. Mods sometimes need to do extra stuff for the specific world.
//		ModLoader.postWorldGen(registries);
		try assets.loadWorldAssets("serverAssets", self.blockPalette);
		try Player.loadFrom(json.getChild("player"));
		Player.id = json.get(u32, "player_id", std.math.maxInt(u32));
	}

	pub fn update(self: *World) !void {
		var newTime: i64 = std.time.milliTimestamp();
		while(self.milliTime +% 100 -% newTime < 0) {
			self.milliTime +%= 100;
			var curTime = self.gameTime.load(.Monotonic);
			while(self.gameTime.tryCompareAndSwap(curTime, curTime +% 1, .Monotonic, .Monotonic)) |actualTime| {
				curTime = actualTime;
			}
		}
		// Ambient light:
		{
			var dayTime = @abs(@mod(self.gameTime.load(.Monotonic), dayCycle) -% dayCycle/2);
			if(dayTime < dayCycle/4 - dayCycle/16) {
				self.ambientLight = 0.1;
				self.clearColor[0] = 0;
				self.clearColor[1] = 0;
				self.clearColor[2] = 0;
			} else if(dayTime > dayCycle/4 + dayCycle/16) {
				self.ambientLight = 1;
				self.clearColor[0] = 0.8;
				self.clearColor[1] = 0.8;
				self.clearColor[2] = 1.0;
			} else {
				// b:
				if(dayTime > dayCycle/4) {
					self.clearColor[2] = @as(f32, @floatFromInt(dayTime - dayCycle/4))/@as(f32, @floatFromInt(dayCycle/16));
				} else {
					self.clearColor[2] = 0;
				}
				// g:
				if(dayTime > dayCycle/4 + dayCycle/32) {
					self.clearColor[1] = 0.8;
				} else if(dayTime > dayCycle/4 - dayCycle/32) {
					self.clearColor[1] = 0.8 + 0.8*@as(f32, @floatFromInt(dayTime - dayCycle/4 - dayCycle/32))/@as(f32, @floatFromInt(dayCycle/16));
				} else {
					self.clearColor[1] = 0;
				}
				// r:
				if(dayTime > dayCycle/4) {
					self.clearColor[0] = 0.8;
				} else {
					self.clearColor[0] = 0.8 + 0.8*@as(f32, @floatFromInt(dayTime - dayCycle/4))/@as(f32, @floatFromInt(dayCycle/16));
				}
				dayTime -= dayCycle/4;
				dayTime <<= 3;
				self.ambientLight = 0.55 + 0.45*@as(f32, @floatFromInt(dayTime))/@as(f32, @floatFromInt(dayCycle/2));
			}
		}
		try network.Protocols.playerPosition.send(self.conn, Player.getPosBlocking(), Player.getVelBlocking(), @intCast(newTime & 65535));
	}
	// TODO:
//	public void drop(ItemStack stack, Vector3d pos, Vector3f dir, float velocity) {
//		Protocols.GENERIC_UPDATE.itemStackDrop(serverConnection, stack, pos, dir, velocity);
//	}
//	public void updateBlock(int x, int y, int z, int newBlock) {
//		NormalChunk ch = getChunk(x, y, z);
//		if (ch != null) {
//			int old = ch.getBlock(x & Chunk.chunkMask, y & Chunk.chunkMask, z & Chunk.chunkMask);
//			if(old != newBlock) {
//				ch.updateBlock(x & Chunk.chunkMask, y & Chunk.chunkMask, z & Chunk.chunkMask, newBlock);
//				Protocols.BLOCK_UPDATE.send(serverConnection, x, y, z, newBlock);
//			}
//		}
//	}
//	/**
//	 * Block update that came from the server. In this case there needs to be no update sent to the server.
//	 */
//	public void remoteUpdateBlock(int x, int y, int z, int newBlock) {
//		NormalChunk ch = getChunk(x, y, z);
//		if (ch != null) {
//			int old = ch.getBlock(x & Chunk.chunkMask, y & Chunk.chunkMask, z & Chunk.chunkMask);
//			if(old != newBlock) {
//				ch.updateBlock(x & Chunk.chunkMask, y & Chunk.chunkMask, z & Chunk.chunkMask, newBlock);
//			}
//		}
//	}
//	public void queueChunks(ChunkData[] chunks) {
//		Protocols.CHUNK_REQUEST.sendRequest(serverConnection, chunks);
//	}
	pub fn getChunk(_: *World, x: i32, y: i32, z: i32) ?*chunk.Chunk {
		return renderer.RenderStructure.getChunk(x, y, z);
	}
//	public void cleanup() {
//		connectionManager.cleanup();
//		ThreadPool.clear();
//	}
//
//	public final BlockInstance getBlockInstance(int x, int y, int z) {
//		VisibleChunk ch = (VisibleChunk)getChunk(x, y, z);
//		if (ch != null && ch.isLoaded()) {
//			return ch.getBlockInstanceAt(Chunk.getIndex(x & Chunk.chunkMask, y & Chunk.chunkMask, z & Chunk.chunkMask));
//		} else {
//			return null;
//		}
//	}
//
//	public int getLight(int x, int y, int z, Vector3f sunLight, boolean easyLighting) {
//		VisibleChunk ch = (VisibleChunk)getChunk(x, y, z);
//		if (ch == null || !ch.isLoaded() || !easyLighting)
//			return 0xffffffff;
//		return ch.getLight(x & Chunk.chunkMask, y & Chunk.chunkMask, z & Chunk.chunkMask);
//	}
//
//	public void getLight(VisibleChunk ch, int x, int y, int z, int[] array) {
//		int block = getBlock(x, y, z);
//		if (block == 0) return;
//		int selfLight = Blocks.light(block);
//		x--;
//		y--;
//		z--;
//		for(int ix = 0; ix < 3; ix++) {
//			for(int iy = 0; iy < 3; iy++) {
//				for(int iz = 0; iz < 3; iz++) {
//					array[ix + iy*3 + iz*9] = getLight(ch, x+ix, y+iy, z+iz, selfLight);
//				}
//			}
//		}
//	}
//
//	protected int getLight(VisibleChunk ch, int x, int y, int z, int minLight) {
//		if (x - ch.wx != (x & Chunk.chunkMask) || y - ch.wy != (y & Chunk.chunkMask) || z - ch.wz != (z & Chunk.chunkMask))
//			ch = (VisibleChunk)getChunk(x, y, z);
//		if (ch == null || !ch.isLoaded())
//			return 0xff000000;
//		int light = ch.getLight(x & Chunk.chunkMask, y & Chunk.chunkMask, z & Chunk.chunkMask);
//		// Make sure all light channels are at least as big as the minimum:
//		if ((light & 0xff000000) >>> 24 < (minLight & 0xff000000) >>> 24) light = (light & 0x00ffffff) | (minLight & 0xff000000);
//		if ((light & 0x00ff0000) < (minLight & 0x00ff0000)) light = (light & 0xff00ffff) | (minLight & 0x00ff0000);
//		if ((light & 0x0000ff00) < (minLight & 0x0000ff00)) light = (light & 0xffff00ff) | (minLight & 0x0000ff00);
//		if ((light & 0x000000ff) < (minLight & 0x000000ff)) light = (light & 0xffffff00) | (minLight & 0x000000ff);
//		return light;
//	}
};
pub var testWorld: World = undefined; // TODO:
pub var world: ?*World = null;

pub var projectionMatrix: Mat4f = Mat4f.identity();

pub var fog = Fog{.color=.{0, 1, 0.5}, .density=1.0/15.0/128.0}; // TODO: Make this depend on the render distance.

pub fn update(deltaTime: f64) !void {
	var movement = Vec3d{0, 0, 0};
	var forward = vec.rotateY(Vec3d{0, 0, -1}, -camera.rotation[1]);
	var right = Vec3d{forward[2], 0, -forward[0]};
	if(main.Window.grabbed) {
		if(KeyBoard.key("forward").pressed) {
			if(KeyBoard.key("sprint").pressed) {
				if(Player.isFlying.load(.Monotonic)) {
					movement += forward*@as(Vec3d, @splat(128));
				} else {
					movement += forward*@as(Vec3d, @splat(8));
				}
			} else {
				movement += forward*@as(Vec3d, @splat(4));
			}
		}
		if(KeyBoard.key("backward").pressed) {
			movement += forward*@as(Vec3d, @splat(-4));
		}
		if(KeyBoard.key("left").pressed) {
			movement += right*@as(Vec3d, @splat(4));
		}
		if(KeyBoard.key("right").pressed) {
			movement += right*@as(Vec3d, @splat(-4));
		}
		if(KeyBoard.key("jump").pressed) {
			if(Player.isFlying.load(.Monotonic)) {
				if(KeyBoard.key("sprint").pressed) {
					movement[1] = 59.45;
				} else {
					movement[1] = 5.45;
				}
			} else { // TODO: if (Cubyz.player.isOnGround())
				movement[1] = 5.45;
			}
		}
		if(KeyBoard.key("fall").pressed) {
			if(Player.isFlying.load(.Monotonic)) {
				if(KeyBoard.key("sprint").pressed) {
					movement[1] = -59.45;
				} else {
					movement[1] = -5.45;
				}
			}
		}
		Player.selectedSlot -%= @bitCast(@as(i32, @intFromFloat(main.Window.scrollOffset)));
		Player.selectedSlot %= 8;
		main.Window.scrollOffset = 0;
	}

	{
		Player.mutex.lock();
		defer Player.mutex.unlock();
		Player.super.pos += movement*@as(Vec3d, @splat(deltaTime));
	}
	try world.?.update();
}