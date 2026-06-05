struct VertexInput{
	float3 position;
}
StructuredBuffer<VertexInput> vertex_data; 

struct VertexOutput{
	float4 position: SV_Position;
	float3 color;
}

[shader("vertex")]
VertexOutput vertexMain(uint vertexID : SV_VulkanVertexID ) {
    	VertexOutput output;
	output.position = float4(vertex_data[vertexID].position, 1.0);
	output.color = float3(0.5 * vertexID, float(vertexID)/2.0, 0.5);
    	return output;
}
[shader("fragment")]
float4 fragmentMain(VertexOutput input) {
    	return float4(input.color, 1.0);
}
