Texture2DMS<float4> _CbrDiffuse0;
Texture2DMS<float4> _CbrDiffuse1;
Texture2DMS<float4> _CbrSpecular0;
Texture2DMS<float4> _CbrSpecular1;
Texture2DMS<float4> _CbrNormal0;
Texture2DMS<float4> _CbrNormal1;
Texture2DMS<float4> _CbrEmission0;
Texture2DMS<float4> _CbrEmission1;
Texture2DMS<float4> _CbrShadowMask0;
Texture2DMS<float4> _CbrShadowMask1;

Texture2DMS<float> _CbrDepth0;
Texture2DMS<float> _CbrDepth1;

static const float2 gTexCoords[6] =
{
	float2(0.0f, 1.0f),
	float2(0.0f, 0.0f),
	float2(1.0f, 0.0f),
	float2(0.0f, 1.0f),
	float2(1.0f, 0.0f),
	float2(1.0f, 1.0f)
};

float _FrameCnt;

// c# code:
// prevInvView = mainCam.cameraToWorldMatrix;
// prevInvProj = mainCam.projectionMatrix.inverse;
// currViewProj = mainCam.projectionMatrix * mainCam.worldToCameraMatrix
float4x4 _PrevInvView;
float4x4 _PrevInvProj;
float4x4 _CurrViewProj;

const float Epsilon = 1.401298E-45;
#define Up		0
#define Down	1
#define Left	2
#define Right	3

float4 readFromQuadrant(Texture2DMS<float4> _CbrFrame0, Texture2DMS<float4> _CbrFrame1, int2 pixel, int quadrant)
{
	[branch]
	if (0 == quadrant)
		return _CbrFrame0.Load(pixel, 1);
	else if (1 == quadrant)
		return _CbrFrame1.Load(pixel + int2(1, 0), 1);
	else if (2 == quadrant)
		return _CbrFrame1.Load(pixel, 0);
	else //( 3 == quadrant )
		return _CbrFrame0.Load(pixel, 0);
}

float readDepthFromQuadrant(int2 pixel, int quadrant)
{
	if (0 == quadrant)
		return _CbrDepth0.Load(pixel, 1);
	else if (1 == quadrant)
		return _CbrDepth1.Load(pixel + int2(1, 0), 1);
	else if (2 == quadrant)
		return _CbrDepth1.Load(pixel, 0);
	else //( 3 == quadrant )
		return _CbrDepth0.Load(pixel, 0);
}

float4 colorFromCardinalOffsets(Texture2DMS<float4> _CbrFrame0, Texture2DMS<float4> _CbrFrame1, uint2 qtr_res_pixel, int2 offsets[4], int quadrants[2])
{
	float4 color[4];

	float2 w;

	color[Up] = readFromQuadrant(_CbrFrame0, _CbrFrame1, qtr_res_pixel + offsets[Up], quadrants[0]);
	color[Down] = readFromQuadrant(_CbrFrame0, _CbrFrame1, qtr_res_pixel + offsets[Down], quadrants[0]);
	color[Left] = readFromQuadrant(_CbrFrame0, _CbrFrame1, qtr_res_pixel + offsets[Left], quadrants[1]);
	color[Right] = readFromQuadrant(_CbrFrame0, _CbrFrame1, qtr_res_pixel + offsets[Right], quadrants[1]);

	return float4((color[Up] + color[Down] + color[Left] + color[Right]) * 0.25f);
}

void getCardinalOffsets(int quadrant, out int2 offsets[4], out int quadrants[2])
{
	if (quadrant == 0)
	{
		offsets[Up] = -int2(0, 1);
		offsets[Down] = 0;
		offsets[Left] = -int2(1, 0);
		offsets[Right] = 0;

		quadrants[0] = 2;
		quadrants[1] = 1;
	}
	else if (quadrant == 1)
	{
		offsets[Up] = -int2(0, 1);
		offsets[Down] = 0;
		offsets[Left] = 0;
		offsets[Right] = +int2(1, 0);

		quadrants[0] = 3;
		quadrants[1] = 0;
	}
	else if (quadrant == 2)
	{
		offsets[Up] = 0;
		offsets[Down] = +int2(0, 1);
		offsets[Left] = -int2(1, 0);
		offsets[Right] = 0;

		quadrants[0] = 0;
		quadrants[1] = 3;
	}
	else // ( quadrant == 3 )
	{
		offsets[Up] = 0;
		offsets[Down] = +int2(0, 1);
		offsets[Left] = 0;
		offsets[Right] = +int2(1, 0);

		quadrants[0] = 1;
		quadrants[1] = 2;
	}
}

float2 CalculateMotion(float2 pixel, float currDepth, float2 res, float4 clipPos)
{
	// no depth buffer information
	[branch]
	if (currDepth <= 0.0)
	{
		return pixel;
	}

	uint2 currPixel = floor(pixel);

	// current clip pos to last frame's view ray, view ray to world pos
	float4 vray = mul(_PrevInvProj, clipPos.xyzw * _ProjectionParams.z);
	float3 vpos = vray.xyz * Linear01Depth(currDepth);
	float3 wpos = mul(_PrevInvView, float4(vpos.xyz, 1)).xyz;

	// proj last frame's world pos to current vp
	float4 newClipPos = mul(_CurrViewProj, float4(wpos, 1.0f));
	newClipPos /= newClipPos.w;
	//newClipPos.xy = newClipPos.xy * 0.5f + 0.5f;

	// normalized motion vector
	return float2(newClipPos.xy - (clipPos.xy /** 0.5f + 0.5f*/));
}

void GetComposeColorDeferred(float2 uv, float4 clipPos
	, inout float4 outDiffuse
	, inout float4 outSpecular
	, inout float4 outNormal
	, inout float4 outEmission
	, inout float4 outShadowMask
	, inout float oDepth
)
{
	uint2 samplePos = uv * _ScreenParams.xy;
	uint2 full_res = _ScreenParams.xy;
	uint2 qtr_res = full_res * .5;
	uint2 full_res_pixel = samplePos.xy;
	uint2 qtr_res_pixel = floor(samplePos.xy * .5);
	uint quadrant = (samplePos.x & 0x1) + (samplePos.y & 0x1) * 2;

	const uint frame_lookup[2][2] =
	{
	   { 0, 3 },
	   { 1, 2 }
	};

	uint frame_quadrants[2];
	frame_quadrants[0] = frame_lookup[_FrameCnt][0];
	frame_quadrants[1] = frame_lookup[_FrameCnt][1];

	[branch]
	if (frame_quadrants[0] == quadrant || frame_quadrants[1] == quadrant)
	{
		// motion vector test
		//float depth = readDepthFromQuadrant(qtr_res_pixel, quadrant);
		//float2 motionVector = CalculateMotion(full_res_pixel + .5f, depth, full_res, clipPos);
		//return float4(motionVector, 0, 1);

		outDiffuse = readFromQuadrant(_CbrDiffuse0, _CbrDiffuse1, qtr_res_pixel, quadrant);
		outSpecular = readFromQuadrant(_CbrSpecular0, _CbrSpecular1, qtr_res_pixel, quadrant);
		outNormal = readFromQuadrant(_CbrNormal0, _CbrNormal1, qtr_res_pixel, quadrant);
		outEmission = readFromQuadrant(_CbrEmission0, _CbrEmission1, qtr_res_pixel, quadrant);
		outShadowMask = readFromQuadrant(_CbrShadowMask0, _CbrShadowMask1, qtr_res_pixel, quadrant);
		oDepth = readDepthFromQuadrant(qtr_res_pixel, quadrant);
	}
	else
	{
		// We need to read from Frame N-1

		int2 cardinal_offsets[4];
		int cardinal_quadrants[2];

		// Get the locations of the pixels in Frame N which surround
		// our current pixel location
		getCardinalOffsets(quadrant, cardinal_offsets, cardinal_quadrants);

		bool missing_pixel = false;

		// What is the depth at this pixel which was written to by Frame N-1
		float depth = readDepthFromQuadrant(qtr_res_pixel, quadrant);
		float2 motionVector = CalculateMotion(full_res_pixel + .5f, depth, full_res, clipPos);
		// motion vector test
		//return float4(motionVector, 0, 1);

		// Project that through the matrices and get the screen space position
		// this pixel was rendered in Frame N-1
		uint2 prev_pixel_pos = full_res_pixel + .5f - motionVector * full_res;
		int2 prev_qtr_res_pixel = floor(prev_pixel_pos * .5f);

		int2 pixel_delta = floor((full_res_pixel + .5f) - prev_pixel_pos);
		int2 qtr_res_pixel_delta = pixel_delta * .5f;

		// Which MSAA quadrant was this pixel in when it was shaded in Frame N-1
		uint quadrant_needed = (prev_pixel_pos.x & 0x1) + (prev_pixel_pos.y & 0x1) * 2;

		if (frame_quadrants[0] == quadrant_needed || frame_quadrants[1] == quadrant_needed)
		{
			missing_pixel = true;
		}
		else if (abs(qtr_res_pixel_delta.x) > Epsilon || abs(qtr_res_pixel_delta.y) > Epsilon)
		{
			missing_pixel = true;
		}

		if (missing_pixel == true)
		{
			outDiffuse = colorFromCardinalOffsets(_CbrDiffuse0, _CbrDiffuse1, qtr_res_pixel, cardinal_offsets, cardinal_quadrants);
			outSpecular = colorFromCardinalOffsets(_CbrSpecular0, _CbrSpecular1, qtr_res_pixel, cardinal_offsets, cardinal_quadrants);
			outNormal = colorFromCardinalOffsets(_CbrNormal0, _CbrNormal1, qtr_res_pixel, cardinal_offsets, cardinal_quadrants);
			outEmission = colorFromCardinalOffsets(_CbrEmission0, _CbrEmission1, qtr_res_pixel, cardinal_offsets, cardinal_quadrants);
			outShadowMask = colorFromCardinalOffsets(_CbrShadowMask0, _CbrShadowMask1, qtr_res_pixel, cardinal_offsets, cardinal_quadrants);
		}
		else
		{
			outDiffuse = readFromQuadrant(_CbrDiffuse0, _CbrDiffuse1, prev_qtr_res_pixel, quadrant_needed);
			outSpecular = readFromQuadrant(_CbrSpecular0, _CbrSpecular1, prev_qtr_res_pixel, quadrant_needed);
			outNormal = readFromQuadrant(_CbrNormal0, _CbrNormal1, prev_qtr_res_pixel, quadrant_needed);
			outEmission = readFromQuadrant(_CbrEmission0, _CbrEmission1, prev_qtr_res_pixel, quadrant_needed);
			outShadowMask = readFromQuadrant(_CbrShadowMask0, _CbrShadowMask1, prev_qtr_res_pixel, quadrant_needed);
		}
		oDepth = readDepthFromQuadrant(qtr_res_pixel, (quadrant + 2) % 4);
	}
}

sampler2D _SkyColor;

struct appdata
{
	float4 vertex : POSITION;
	float2 uv : TEXCOORD;
};

struct v2f
{
	float4 vertex : SV_POSITION;
	float2 uv : TEXCOORD0;
	float4 clipPos : TEXCOORD1;
};

v2f vertComposeCBR(appdata v, uint vid : SV_VertexID)
{
	v2f o;
	o.uv = gTexCoords[vid];
	o.clipPos = float4(o.uv.xy * 2 - 1, 0, 1);
	o.vertex = o.clipPos;

	return o;
}

void fragDeferredComposeCBR(v2f i
	, out float4 outDiffuse : SV_Target0
	, out float4 outSpecular : SV_Target1
	, out float4 outNormal : SV_Target2
	, out float4 outEmission : SV_Target3
	, out float4 outShadowMask : SV_Target4
	, out float oDepth : SV_Depth)
{
	i.uv.y = 1 - i.uv.y;
	GetComposeColorDeferred(i.uv, i.clipPos, outDiffuse, outSpecular, outNormal, outEmission, outShadowMask, oDepth);

	// adjust emission
	outEmission = lerp(outEmission, tex2D(_SkyColor, i.uv), outEmission.a < 0);
}