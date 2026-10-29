// Writes 1 into a raw buffer if any pixel of |a| differs from |b|. Both
// textures are B8G8R8A8_UNORM of the same size; unorm loads of equal bytes
// yield equal floats, so the comparison is exact.
//
// Regenerate frame_compare_cs.h after editing (Windows SDK fxc):
//   fxc /nologo /T cs_5_0 /E main /Vn kFrameCompareCs /Fh frame_compare_cs.h frame_compare.hlsl
Texture2D<float4> a : register(t0);
Texture2D<float4> b : register(t1);
RWByteAddressBuffer result : register(u0);

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
  uint width, height;
  a.GetDimensions(width, height);
  if (id.x >= width || id.y >= height) {
    return;
  }
  if (any(a.Load(int3(id.xy, 0)) != b.Load(int3(id.xy, 0)))) {
    result.Store(0, 1u);
  }
}
