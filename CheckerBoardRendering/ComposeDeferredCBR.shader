Shader "CheckerBoardRendering/ComposeDeferredCBR"
{
    Properties
    {

    }
    SubShader
    {
        // No culling but need depth, we will reconstruct depth buffer
        Cull Off ZWrite On ZTest Always

		// carry stencil value for lighting
		Stencil
		{
			Ref 128
			Comp always
			Pass replace
		}

        Pass
        {
            CGPROGRAM
            #pragma vertex vertComposeCBR
            #pragma fragment fragDeferredComposeCBR
			#pragma target 5.0
            #include "UnityCG.cginc"
			#include "ComposeCBR.cginc"

            ENDCG
        }
    }
}
