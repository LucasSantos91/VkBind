struct VertexOutput{
	float4 position: SV_Position;
	float4 color;
}

[shader("vertex")]
VertexOutput vertexMain(uint vertexID : SV_VulkanVertexID) {
    VertexOutput o;
    // Full‑screen triangle in Vulkan clip space (Y down)
    const float2 pos[3] = {
        float2(-1, -3),   // top
        float2(-1,  1),   // bottom‑left
        float2( 3,  1)    // bottom‑right
    };
    o.position = float4(pos[vertexID], 0.0, 1.0);
    o.color = float4(0,1,0,1);   // green
    return o;
}
[shader("fragment")]
float4 fragmentMain(VertexOutput v) {
    	return v.color;
}
