const std = @import("std");
const vk_bind = @import("VkBind");
const debug_commands: []const vk_bind.raw.Command = &.{
    .destroyInstance,
    .destroyDevice,
    .destroyCommandPool,
    .destroyPipeline,
    .destroySurfaceKHR,
    .destroyPipelineLayout,
    .destroyDescriptorSetLayout,
    .destroyRenderPass,
    .destroyFramebuffer,
    .destroyFence,
    .destroySemaphore,
};
const surface_ext: vk_bind.raw.Extension = switch (builtin.target.os.tag) {
    .windows => .KHR_win32_surface,
    else => @compileError("Not implemented yet"),
};
const vk = vk_bind.VulkanContext(.{
    .commands = [_]vk_bind.raw.Command{
        .createInstance,
        .createDevice,
        .getPhysicalDeviceFeatures,
        .enumeratePhysicalDevices,
        .getPhysicalDeviceQueueFamilyProperties,
        .createCommandPool,
        .allocateCommandBuffers,
        .createDescriptorSetLayout,
        .createPipelineLayout,
        .createShaderModule,
        .destroyShaderModule,
        .createRenderPass,
        .createGraphicsPipelines,
        .enumerateDeviceExtensionProperties,
        .getPhysicalDeviceSurfaceSupportKHR,
        .createImageView,
        .getDeviceQueue,
        .createSwapchainKHR,
        .getPhysicalDeviceSurfaceCapabilitiesKHR,
        .getPhysicalDeviceSurfaceFormatsKHR,
        .getSwapchainImagesKHR,
        .destroyImageView,
        .destroySwapchainKHR,
        .getPhysicalDeviceFeatures2,
        .createFramebuffer,
        .createSemaphore,
        .createFence,
        .resetFences,
        .waitForFences,
        .acquireNextImageKHR,
        .beginCommandBuffer,
        .endCommandBuffer,
        .resetCommandBuffer,
        .cmdBeginRenderPass,
        .cmdSetViewport,
        .cmdDraw,
        .queueSubmit,
        .queuePresentKHR,
        .cmdBindPipeline,
        .deviceWaitIdle,
        .cmdEndRenderPass,
    } ++ debug_commands,
    .extensions = &([_]vk_bind.raw.Extension{
        .KHR_surface,
        surface_ext,
        .KHR_swapchain,
        .KHR_get_physical_device_properties2,
    } ++
        [_]vk_bind.raw.Extension{ .KHR_portability_enumeration, .KHR_portability_subset }) // Must be the last ones
    ,
    .apiVersion = .{ .minor = 0 }
});
const builtin = @import("builtin");
const is_safe = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const glfw = @import("glfw-zig");
const assert = std.debug.assert;

const Context = struct {
    fn panic(err: anyerror, motive: []const u8) noreturn {
        std.debug.panic(
            \\Panic in Vulkan.
            \\{s}
            \\Error code: {t},
        , .{ motive, err });
    }
    const Temp = struct {
        instance: vk.Instance,
        command_pool: vk.CommandPool,
        pipeline_layout: vk.PipelineLayout,
    };
    const Image = struct {
        image: vk.Image,
        view: vk.ImageView,
        framebuffer: vk.Framebuffer,
    };

    temp: if (is_safe) Temp else void,
    device: vk.Device,
    command_buffer: vk.CommandBuffer,
    surface: vk.SurfaceKHR,
    pipeline: vk.Pipeline,
    window: *glfw.GLFWwindow,
    render_pass: vk.RenderPass,
    queue: vk.Queue,
    swapchain: vk.SwapchainKHR,
    swapchain_images: [max_swapchain_images]Image,
    swapchain_images_len: u32,
    swapchain_extent: vk.Extent2D,
    image_available: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_in_flight: vk.Fence,

    const max_swapchain_images = 16;

    fn initWindow(self: *@This(), instance: vk.Instance, instance_proc_address: vk.Command.getInstanceProcAddr.GetPtrType()) void {
        std.debug.assert(glfw.glfwInit() == glfw.GLFW_TRUE);
        glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
        self.window = glfw.glfwCreateWindow(640, 480, "Triangle", null, null).?;
        glfw.glfwInitVulkanLoader(@ptrCast(instance_proc_address));
        std.debug.assert(glfw.glfwCreateWindowSurface(@ptrFromInt(@intFromEnum(instance)), self.window, null, @ptrCast(&self.surface)) == @intFromEnum(vk.Result.SUCCESS));
    }
    fn isExtensionInList(haystack: []const vk.ExtensionProperties, needle: [*:0]const u8) bool {
        for (haystack) |p| {
            if (std.mem.orderZ(u8, @ptrCast(&p.extensionName), needle) == .eq)
                return true;
        }
        return false;
    }
    fn Ptr(comptime T: type) type {
        const i = @typeInfo(T).pointer;
        return @Pointer(.many, i.attrs, i.child, i.sentinel());
    }

    pub fn init() @This() {
        var self: @This() = undefined;

        const enumerate_portability = blk: {
            var buffer: [512]vk.ExtensionProperties = undefined;
            var count: u32 = buffer.len;
            assert(vk.globals.enumerateInstanceExtensionProperties(null, &count, &buffer) catch |e| panic(e, "Failed to enumerate instance extension properties") == .SUCCESS);
            break :blk isExtensionInList(buffer[0..count], vk.Extension.KHR_portability_enumeration.getVkName());
        };

        const instance_create_info: vk.InstanceCreateInfo = .{
            .enabledExtensionCount = if (enumerate_portability) vk.extensions.instance.len else vk.extensions.instance.len - 1,
            .ppEnabledExtensionNames = vk.extensions.instance.ptr,
            .flags = .{ .ENUMERATE_PORTABILITY_KHR = enumerate_portability },
            .pApplicationInfo = &.{ .apiVersion = vk.apiVersion, .applicationVersion = 0, .engineVersion = 0 },
        };
        const instance = vk.globals.createInstance(&instance_create_info) catch |e| panic(e, "Failed to create instance");
        const inst_proc_addr = vk.getSpecializedGetInstanceProcAddr(instance).?;
        vk.initInstanceCommands(inst_proc_addr, instance);
        self.initWindow(instance, inst_proc_addr);
        const phys_device, const family_index, const portability_subset = selectPhysicalDeviceAndQueueFamily(instance, self.surface);
        const queue_create_info: [1]vk.DeviceQueueCreateInfo = .{vk.DeviceQueueCreateInfo{
            .queueFamilyIndex = family_index,
            .queueCount = 1,
            .pQueuePriorities = &.{1.0},
        }};

        const features: vk.PhysicalDeviceFeatures = .{
            .fullDrawIndexUint32 = .false,
            .imageCubeArray = .false,
            .independentBlend = .false,
            .geometryShader = .false,
            .tessellationShader = .false,
            .sampleRateShading = .false,
            .dualSrcBlend = .false,
            .logicOp = .false,
            .multiDrawIndirect = .false,
            .drawIndirectFirstInstance = .false,
            .depthClamp = .false,
            .depthBiasClamp = .false,
            .fillModeNonSolid = .false,
            .depthBounds = .false,
            .wideLines = .false,
            .largePoints = .false,
            .alphaToOne = .false,
            .multiViewport = .false,
            .samplerAnisotropy = .false,
            .textureCompressionETC2 = .false,
            .textureCompressionASTC_LDR = .false,
            .textureCompressionBC = .false,
            .occlusionQueryPrecise = .false,
            .pipelineStatisticsQuery = .false,
            .vertexPipelineStoresAndAtomics = .false,
            .fragmentStoresAndAtomics = .false,
            .shaderTessellationAndGeometryPointSize = .false,
            .shaderImageGatherExtended = .false,
            .shaderStorageImageExtendedFormats = .false,
            .shaderStorageImageMultisample = .false,
            .shaderStorageImageReadWithoutFormat = .false,
            .shaderStorageImageWriteWithoutFormat = .false,
            .shaderUniformBufferArrayDynamicIndexing = .false,
            .shaderSampledImageArrayDynamicIndexing = .false,
            .shaderStorageBufferArrayDynamicIndexing = .false,
            .shaderStorageImageArrayDynamicIndexing = .false,
            .shaderClipDistance = .false,
            .shaderCullDistance = .false,
            .shaderFloat64 = .false,
            .shaderInt64 = .false,
            .shaderInt16 = .false,
            .shaderResourceResidency = .false,
            .shaderResourceMinLod = .false,
            .sparseBinding = .false,
            .sparseResidencyBuffer = .false,
            .sparseResidencyImage2D = .false,
            .sparseResidencyImage3D = .false,
            .sparseResidency2Samples = .false,
            .sparseResidency4Samples = .false,
            .sparseResidency8Samples = .false,
            .sparseResidency16Samples = .false,
            .sparseResidencyAliased = .false,
            .variableMultisampleRate = .false,
            .inheritedQueries = .false,
            .robustBufferAccess = .false,
        };
        const device_create_info: vk.DeviceCreateInfo = .{
            .enabledExtensionCount = if (portability_subset) vk.extensions.device.len else vk.extensions.device.len - 1,
            .ppEnabledExtensionNames = vk.extensions.device.ptr,
            .queueCreateInfoCount = queue_create_info.len,
            .pQueueCreateInfos = &queue_create_info,
            .pEnabledFeatures = &features,
        };
        self.device = phys_device.createDevice(&device_create_info) catch |e| panic(e, "Failed to create device");
        vk.initDeviceCommandsFromGetInstanceProcAddr(inst_proc_addr, instance, self.device);
        self.queue = self.device.getDeviceQueue(family_index, 0);
        const surface_capabilities = phys_device.getPhysicalDeviceSurfaceCapabilitiesKHR(self.surface) catch |e| panic(e, "Failed to get surface capabilities");
        const format = blk: {
            var format_buffer: [1]vk.SurfaceFormatKHR = undefined;
            var format_count: u32 = format_buffer.len;
            _ = phys_device.getPhysicalDeviceSurfaceFormatsKHR(self.surface, &format_count, &format_buffer) catch |e| panic(e, "Failed to get physical device surface formats");
            break :blk format_buffer[0];
        };
        self.swapchain_extent =
            if (surface_capabilities.currentExtent.width != std.math.maxInt(u32)) surface_capabilities.currentExtent else .{
                .width = std.math.clamp(surface_capabilities.currentExtent.width, surface_capabilities.minImageExtent.width, surface_capabilities.maxImageExtent.width),
                .height = std.math.clamp(surface_capabilities.currentExtent.height, surface_capabilities.minImageExtent.height, surface_capabilities.maxImageExtent.height),
            };

        const command_pool = self.device.createCommandPool(&.{
            .queueFamilyIndex = family_index,
            .flags = .{ .RESET_COMMAND_BUFFER = true },
        }) catch |e| panic(e, "Failed to create command pool");

        self.device.allocateCommandBuffers(&.{
            .commandPool = command_pool,
            .level = .PRIMARY,
            .commandBufferCount = 1,
        }, @as(*[1]vk.CommandBuffer, &self.command_buffer)) catch |e| panic(e, "Failed to allocate command buffers");

        const pipeline_layout_create_info: vk.PipelineLayoutCreateInfo = .{
            .setLayoutCount = 0,
            .pSetLayouts = undefined,
        };
        const pipeline_layout = self.device.createPipelineLayout(&pipeline_layout_create_info) catch |e| panic(e, "Failed to create pipeline layout");
        const color_attachment_reference: vk.AttachmentReference = .{
            .attachment = 0,
            .layout = .COLOR_ATTACHMENT_OPTIMAL,
        };
        const subpass_description: vk.SubpassDescription = .{
            .inputAttachmentCount = 0,
            .pInputAttachments = undefined,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = undefined,
            .colorAttachmentCount = 1,
            .pColorAttachments = @ptrCast(&color_attachment_reference),
            .pResolveAttachments = undefined,
            .pDepthStencilAttachment = undefined,
            .pipelineBindPoint = .GRAPHICS,
        };
        const color_attachment: vk.AttachmentDescription = .{
            .initialLayout = .UNDEFINED,
            .finalLayout = .PRESENT_SRC_KHR,
            .samples = .@"1",
            .loadOp = .CLEAR,
            .storeOp = .STORE,
            .stencilLoadOp = .DONT_CARE,
            .stencilStoreOp = .DONT_CARE,
            .format = format.format,
        };
        const dependencies: vk.SubpassDependency = .{
            .srcSubpass = vk.SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = .{ .COLOR_ATTACHMENT_OUTPUT = true },
            .srcAccessMask = .{ .COLOR_ATTACHMENT_READ = true },
            .dstStageMask = .{ .COLOR_ATTACHMENT_OUTPUT = true },
            .dstAccessMask = .{ .COLOR_ATTACHMENT_WRITE = true },
        };
        const render_pass_create_info: vk.RenderPassCreateInfo = .{
            .subpassCount = 1,
            .pSubpasses = @ptrCast(&subpass_description),
            .attachmentCount = 1,
            .pAttachments = @ptrCast(&color_attachment),
            .dependencyCount = 1,
            .pDependencies = @ptrCast(&dependencies),
        };
        self.render_pass = self.device.createRenderPass(&render_pass_create_info) catch |e| panic(e, "Failed to create render pass");

        const desired_swapchain_images = 2;
        const swapchain_create_info: vk.SwapchainCreateInfoKHR = .{
            .clipped = .true,
            .compositeAlpha = .OPAQUE_KHR,
            .flags = .{},
            .imageArrayLayers = 1,
            .imageColorSpace = format.colorSpace,
            .imageExtent = self.swapchain_extent,
            .imageFormat = format.format,
            .imageSharingMode = .EXCLUSIVE,
            .imageUsage = .{ .COLOR_ATTACHMENT = true },
            .minImageCount = std.math.clamp(
                desired_swapchain_images,
                surface_capabilities.minImageCount,
                if (surface_capabilities.maxImageCount == 0) std.math.maxInt(u32) else surface_capabilities.maxImageCount,
            ),
            .queueFamilyIndexCount = 1,
            .pQueueFamilyIndices = &.{family_index},
            .preTransform = surface_capabilities.currentTransform,
            .presentMode = .FIFO_KHR,
            .surface = self.surface,
            .oldSwapchain = .null_handle,
        };
        self.swapchain = self.device.createSwapchainKHR(&swapchain_create_info) catch |e| panic(e, "Failed to create swapchain");

        self.swapchain_images_len = max_swapchain_images;
        var buffer: [max_swapchain_images]vk.Image = undefined;
        assert(self.device.getSwapchainImagesKHR(self.swapchain, &self.swapchain_images_len, &buffer) catch |e| panic(e, "Failed to get swapchain images") == .SUCCESS);
        for (self.swapchain_images[0..self.swapchain_images_len], buffer[0..self.swapchain_images_len]) |*dst, src| {
            const view_create_info: vk.ImageViewCreateInfo = .{
                .flags = .{},
                .format = format.format,
                .image = src,
                .viewType = .@"2D",
                .subresourceRange = .{
                    .layerCount = 1,
                    .baseArrayLayer = 0,
                    .levelCount = 1,
                    .baseMipLevel = 0,
                    .aspectMask = .{ .COLOR = true },
                },
                .components = .{
                    .a = .IDENTITY,
                    .r = .IDENTITY,
                    .g = .IDENTITY,
                    .b = .IDENTITY,
                },
            };
            dst.* = .{
                .image = src,
                .view = self.device.createImageView(&view_create_info) catch |e| panic(e, "Failed to create image view"),
                .framebuffer = undefined,
            };
            const framebuffer_create_info: vk.FramebufferCreateInfo = .{
                .renderPass = self.render_pass,
                .attachmentCount = 1,
                .pAttachments = &.{dst.view},
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .layers = 1,
            };
            dst.framebuffer = self.device.createFramebuffer(&framebuffer_create_info) catch |e| panic(e, "Failed to create framebuffer");
        }

        const shaders_code align(@alignOf(u32)) = comptime @embedFile("shaders").*;
        const shaders_module_create_info: vk.ShaderModuleCreateInfo = .{
            .pCode = @ptrCast(&shaders_code),
            .codeSize = comptime shaders_code.len,
        };
        const shaders_module = self.device.createShaderModule(&shaders_module_create_info) catch |e| panic(e, "Failed to create shader module");
        defer self.device.destroyShaderModule(shaders_module);
        const pipeline_create_info: vk.GraphicsPipelineCreateInfo = .{
            .layout = pipeline_layout,
            .flags = .{},
            .pColorBlendState = &vk.PipelineColorBlendStateCreateInfo{
                .logicOpEnable = .false,
                .logicOp = undefined,
                .blendConstants = undefined,
                .attachmentCount = 1,
                .pAttachments = &.{vk.PipelineColorBlendAttachmentState{
                    .blendEnable = .false,
                    .colorBlendOp = undefined,
                    .alphaBlendOp = undefined,
                    .srcAlphaBlendFactor = undefined,
                    .srcColorBlendFactor = undefined,
                    .dstAlphaBlendFactor = undefined,
                    .dstColorBlendFactor = undefined,
                }},
            },
            .pDepthStencilState = &vk.PipelineDepthStencilStateCreateInfo{
                .depthBoundsTestEnable = .false,
                .depthWriteEnable = undefined,
                .depthCompareOp = undefined,
                .stencilTestEnable = undefined,
                .front = undefined,
                .back = undefined,
                .minDepthBounds = undefined,
                .maxDepthBounds = undefined,
                .depthTestEnable = undefined,
            },
            .pDynamicState = &vk.PipelineDynamicStateCreateInfo{
                .dynamicStateCount = 1,
                .pDynamicStates = &.{.VIEWPORT},
            },
            .pMultisampleState = &vk.PipelineMultisampleStateCreateInfo{
                .sampleShadingEnable = .false,
                .alphaToCoverageEnable = .false,
                .alphaToOneEnable = .false,
                .rasterizationSamples = .@"1",
                .minSampleShading = undefined,
            },
            .pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo{
                .topology = .TRIANGLE_LIST,
                .primitiveRestartEnable = .false,
            },
            .pRasterizationState = &vk.PipelineRasterizationStateCreateInfo{
                .lineWidth = 1,
                .rasterizerDiscardEnable = .false,
                .polygonMode = .FILL,
                .frontFace = .CLOCKWISE,
                .depthBiasEnable = .false,
                .depthClampEnable = .false,
                .depthBiasConstantFactor = undefined,
                .depthBiasClamp = undefined,
                .depthBiasSlopeFactor = undefined,
            },
            .stageCount = 2,
            .pStages = &.{
                vk.PipelineShaderStageCreateInfo{
                    .stage = .VERTEX,
                    .pName = "vertMain",
                    .module = shaders_module,
                },
                vk.PipelineShaderStageCreateInfo{
                    .stage = .FRAGMENT,
                    .pName = "fragMain",
                    .module = shaders_module,
                },
            },
            .pTessellationState = &vk.PipelineTessellationStateCreateInfo{
                .patchControlPoints = undefined,
            },
            .pVertexInputState = &vk.PipelineVertexInputStateCreateInfo{},
            .pViewportState = &vk.PipelineViewportStateCreateInfo{
                .scissorCount = 1,
                .pScissors = &.{vk.Rect2D{ .offset = .{
                    .x = 0,
                    .y = 0,
                }, .extent = .{
                    .width = std.math.maxInt(i32),
                    .height = std.math.maxInt(i32),
                } }},
                .viewportCount = 1,
            },
            .subpass = 0,
            .renderPass = self.render_pass,
            .basePipelineIndex = 0,
        };
        assert(self.device.createGraphicsPipelines(.null_handle, 1, &.{pipeline_create_info}, @ptrCast(
            &self.pipeline,
        )) catch |e| panic(e, "Failed to create pipeline") == .SUCCESS);
        self.image_available = self.device.createSemaphore(&.{}) catch |e| panic(e, "Failed to create semaphore");
        self.render_finished = self.device.createSemaphore(&.{}) catch |e| panic(e, "Failed to create semaphore");
        self.frame_in_flight = self.device.createFence(&.{ .flags = .{ .SIGNALED = true } }) catch |e| panic(e, "Failed to create fence");

        if (comptime is_safe) {
            self.temp = .{
                .instance = instance,
                .command_pool = command_pool,
                .pipeline_layout = pipeline_layout,
            };
        }
        return self;
    }
    pub fn deinit(self: *@This()) void {
        if (comptime is_safe) {
            self.device.deviceWaitIdle() catch |e| panic(e, "Failed to wait device idle");
            self.device.destroyFence(self.frame_in_flight);
            self.device.destroySemaphore(self.image_available);
            self.device.destroySemaphore(self.render_finished);
            for (self.swapchain_images[0..self.swapchain_images_len]) |i| {
                self.device.destroyFramebuffer(i.framebuffer);
                self.device.destroyImageView(i.view);
            }
            self.device.destroySwapchainKHR(self.swapchain);
            self.device.destroyPipeline(self.pipeline);
            self.device.destroyPipelineLayout(self.temp.pipeline_layout);
            self.device.destroyRenderPass(self.render_pass);
            self.device.destroyCommandPool(self.temp.command_pool);
            self.temp.instance.destroySurfaceKHR(self.surface);
            self.device.destroyDevice();
            self.temp.instance.destroyInstance();
            glfw.glfwTerminate();
            self.* = undefined;
        }
    }
    pub fn run(self: *@This()) !void {
        self.draw();
        while (glfw.glfwWindowShouldClose(self.window) == 0) {
            glfw.glfwWaitEvents();
        }
    }
    fn handleOutOfDate(self: *@This()) void {
        _ = self;
    }
    fn draw(self: *@This()) void {
        self.device.deviceWaitIdle() catch |e| panic(e, "Failed to wait device idle");
        assert(self.device.waitForFences(1, &.{self.frame_in_flight}, .true, std.math.maxInt(u64)) catch |e| panic(e, "Failed to wait for fence") == .SUCCESS);
        self.device.resetFences(1, &.{self.frame_in_flight}) catch |e| panic(e, "Failed to reset fence");

        var swapchain_index: u32 = undefined;
        const acquire_result = self.device.acquireNextImageKHR(self.swapchain, std.math.maxInt(u64), self.image_available, .null_handle, &swapchain_index) catch |e| switch (e) {
            error.OUT_OF_HOST_MEMORY, error.OUT_OF_DEVICE_MEMORY, error.DEVICE_LOST, error.SURFACE_LOST_KHR => |err| panic(err, "Failed to acquire swapchain image"),
            error.OUT_OF_DATE_KHR => {
                self.handleOutOfDate();
                @panic("Not implemented yet");
            },
            error.FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT => unreachable,
        };
        switch (acquire_result) {
            .SUCCESS => {},
            .TIMEOUT => unreachable,
            .NOT_READY => {},
            .SUBOPTIMAL_KHR => {},
        }
        self.command_buffer.resetCommandBuffer(.{}) catch |e| panic(e, "Failed to reset command buffer");
        self.command_buffer.beginCommandBuffer(&.{}) catch |e| panic(e, "Failed to begin command buffer");
        self.command_buffer.cmdBindPipeline(.GRAPHICS, self.pipeline);
        const render_pass_begin: vk.RenderPassBeginInfo = .{
            .renderPass = self.render_pass,
            .framebuffer = self.swapchain_images[swapchain_index].framebuffer,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapchain_extent,
            },
            .clearValueCount = 1,
            .pClearValues = &.{.{ .color = .{ .float32 = .{ 1, 0, 0, 1 } } }},
        };
        self.command_buffer.cmdBeginRenderPass(&render_pass_begin, .INLINE);
        const viewport: vk.Viewport = .{
            .x = 0,
            .y = 0,
            .height = @floatFromInt(self.swapchain_extent.height),
            .width = @floatFromInt(self.swapchain_extent.width),
            .minDepth = 0,
            .maxDepth = 1,
        };
        self.command_buffer.cmdSetViewport(0, 1, @ptrCast(&viewport));
        self.command_buffer.cmdDraw(3, 1, 0, 0);
        self.command_buffer.cmdEndRenderPass();
        self.command_buffer.endCommandBuffer() catch |e| panic(e, "Failed to end command buffer");

        const submit_info: vk.SubmitInfo = .{
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast(&self.command_buffer),
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = @ptrCast(&self.image_available),
            .pWaitDstStageMask = &.{.{ .COLOR_ATTACHMENT_OUTPUT = true }},
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = @ptrCast(&self.render_finished),
        };
        self.queue.queueSubmit(1, @ptrCast(&submit_info), self.frame_in_flight) catch |e| panic(e, "Failed to submit to queue");
        const present_info: vk.PresentInfoKHR = .{
            .swapchainCount = 1,
            .pSwapchains = @ptrCast(&self.swapchain),
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = @ptrCast(&self.render_finished),
            .pImageIndices = @ptrCast(&swapchain_index),
        };
        switch (self.queue.queuePresentKHR(&present_info) catch |e| panic(e, "Failed to present")) {
            .SUCCESS => {},
            .SUBOPTIMAL_KHR => self.handleOutOfDate(),
        }
    }
    fn selectPhysicalDeviceAndQueueFamily(instance: vk.Instance, surface: vk.SurfaceKHR) struct { vk.PhysicalDevice, u4, bool } {
        var physical_devices: [16]vk.PhysicalDevice = undefined;
        var count: u32 = physical_devices.len;
        _ = instance.enumeratePhysicalDevices(&count, &physical_devices) catch |e| panic(e, "Failed to enumerate physical devices");
        outer: for (physical_devices[0..count]) |p| {
            var buffer: [512]vk.ExtensionProperties = undefined;
            var extension_count: u32 = buffer.len;
            assert(p.enumerateDeviceExtensionProperties(null, &extension_count, &buffer) catch |e| panic(e, "Failed to enumerate device extension properties") == .SUCCESS);
            const ext = buffer[0..extension_count];
            for (vk.extensions.device[0 .. vk.extensions.device.len - 1]) |de| {
                if (!isExtensionInList(ext, de)) continue :outer;
            }
            var props: [16]vk.QueueFamilyProperties = undefined;
            var len: u32 = props.len;
            p.getPhysicalDeviceQueueFamilyProperties(&len, &props);
            for (props[0..len], 0..) |prop, index| {
                const present = p.getPhysicalDeviceSurfaceSupportKHR(@intCast(index), surface) catch |e| panic(e, "Failed to get device surface support");
                if (present == .false) continue;
                if (prop.queueFlags.GRAPHICS) {
                    return .{
                        p,
                        @intCast(index),
                        isExtensionInList(ext, vk.Extension.KHR_portability_subset.getVkName()),
                    };
                }
            }
        } else {
            @panic("Failed to find adequate physical device");
        }
    }
};

pub fn main() void {
    var context: Context = .init();
    try context.run();
    if (comptime is_safe) {
        context.deinit();
    }
}
