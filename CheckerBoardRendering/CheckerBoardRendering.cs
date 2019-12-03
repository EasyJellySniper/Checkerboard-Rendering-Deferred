using System;
using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.Rendering;

/// <summary>
/// CBR 2x Rendering, attach to camera
/// </summary>
[RequireComponent(typeof(Camera))]
public class CheckerBoardRendering : MonoBehaviour
{
    [DllImport("CBR", CallingConvention = CallingConvention.Cdecl)]
    extern static bool CacheNativeGBuffer(IntPtr _src, int _frame, int _gBufferId);

    [DllImport("CBR", CallingConvention = CallingConvention.Cdecl)]
    extern static bool CacheNativeDepth(IntPtr _src, int _frame);

    [DllImport("CBR", CallingConvention = CallingConvention.Cdecl)]
    extern static void ReleaseNativeCBR();

    [DllImport("CBR", CallingConvention = CallingConvention.Cdecl)]
    extern static IntPtr GetRenderEventFunc();

    const int NumOfGBuffer = 5;

    /// <summary>
    /// compose CBR material
    /// </summary>
    public Material composeCBR;

    /// <summary>
    /// execute awake
    /// </summary>
    public bool initInAwake = false;

    Camera mainCam;
    RenderTexture[] cbrGBuffer0;
    RenderTexture[] cbrGBuffer1;
    RenderTexture cbrDepth0;
    RenderTexture cbrDepth1;
    RenderTexture skyRT;
    Rect cbrRect;
    int frameCnt = 0;

    CommandBuffer setCbrGBuffer;
    CommandBuffer composeCbrGBuffer;
    Mesh customQuad;

    Matrix4x4 prevInvView;
    Matrix4x4 prevInvProj;
    Matrix4x4 clipToWorld;

    /// <summary>
    /// init
    /// </summary>
    public void Initialize()
    {
        if (!composeCBR)
        {
            Debug.LogError("Didn't set compose CBR material");
            enabled = false;
            return;
        }

        Init();
        frameCnt = 0;

        if (!initInAwake)
        {
            OnEnable();
        }
    }

    void Awake()
    {
        mainCam = GetComponent<Camera>();
        if (initInAwake)
        {
            Initialize();
        }
    }

    void OnEnable()
    {
        EnableCommand();
        mainCam.clearFlags = CameraClearFlags.Color;
    }

    void OnDisable()
    {
        DisableCommand();
        mainCam.clearFlags = CameraClearFlags.Skybox;
    }

    void OnPreCull()
    {
        RenderTexture activeRT = RenderTexture.active;
        Graphics.SetRenderTarget(skyRT);
        GL.ClearWithSkybox(false, mainCam);
        Graphics.SetRenderTarget(activeRT);

        if (composeCBR)
        {
            composeCBR.SetMatrix("_PrevInvView", prevInvView);
            composeCBR.SetMatrix("_PrevInvProj", prevInvProj);
            composeCBR.SetMatrix("_CurrViewProj", mainCam.projectionMatrix * mainCam.worldToCameraMatrix);
            composeCBR.SetFloat("_FrameCnt", frameCnt);
            composeCBR.SetTexture("_SkyColor", skyRT);
        }

        frameCnt = (frameCnt + 1) % 2;

        prevInvView = mainCam.cameraToWorldMatrix;
        prevInvProj = mainCam.projectionMatrix.inverse;
    }

    void OnDestroy()
    {
        if (setCbrGBuffer != null)
        {
            setCbrGBuffer.Release();
        }

        if (composeCbrGBuffer != null)
        {
            composeCbrGBuffer.Release();
        }

        if (customQuad)
        {
            DestroyImmediate(customQuad);
        }

        ReleaseNativeCBR();
        ReleaseCBR();
    }

    void EnableCommand()
    {
        if (mainCam.actualRenderingPath == RenderingPath.DeferredShading)
        {
            if (setCbrGBuffer != null)
            {
                mainCam.AddCommandBuffer(CameraEvent.BeforeGBuffer, setCbrGBuffer);
            }

            if (composeCbrGBuffer != null)
            {
                mainCam.AddCommandBuffer(CameraEvent.AfterGBuffer, composeCbrGBuffer);
            }
        }
    }

    void DisableCommand()
    {
        if (mainCam.actualRenderingPath == RenderingPath.DeferredShading)
        {
            if (setCbrGBuffer != null)
            {
                mainCam.RemoveCommandBuffer(CameraEvent.BeforeGBuffer, setCbrGBuffer);
            }

            if (composeCbrGBuffer != null)
            {
                mainCam.RemoveCommandBuffer(CameraEvent.AfterGBuffer, composeCbrGBuffer);
            }
        }
    }

    void Init()
    {
        // create rect
        cbrRect = new Rect(0, 0, mainCam.pixelWidth / 2, mainCam.pixelHeight / 2);

        // create custom quad
        customQuad = new Mesh();
        customQuad.name = "Custom Quad";
        customQuad.vertices = new Vector3[6];
        int[] indices = { 0, 1, 2, 3, 4, 5 };
        customQuad.SetTriangles(indices, 0);
        customQuad.UploadMeshData(true);

        // init skycolor, for lerp black edge
        skyRT = new RenderTexture(mainCam.pixelWidth / 4, mainCam.pixelHeight / 4, 0, RenderTextureFormat.ARGB32);
        skyRT.name = "Sky Texture";

        if (mainCam.actualRenderingPath == RenderingPath.DeferredShading)
        {
            InitDeferred();
        }
    }

    void InitDeferred()
    {
        cbrGBuffer0 = new RenderTexture[NumOfGBuffer];
        cbrGBuffer1 = new RenderTexture[NumOfGBuffer];
        RenderTextureFormat[] gBufferFormat = { RenderTextureFormat.ARGB32, RenderTextureFormat.ARGB32, RenderTextureFormat.ARGB2101010, RenderTextureFormat.ARGBHalf, RenderTextureFormat.ARGB32 };
        string[] gBufferName = { "CBR Diffuse", "CBR Specular", "CBR Normal", "CBR Emission", "CBR Shadowmask" };

        // create GBuffer
        for (int i = 0; i < NumOfGBuffer; i++)
        {
            cbrGBuffer0[i] = CreateCBRTexture(mainCam.pixelWidth / 2, mainCam.pixelHeight / 2, 0, gBufferFormat[i], gBufferName[i] + "0");
            cbrGBuffer1[i] = CreateCBRTexture(mainCam.pixelWidth / 2, mainCam.pixelHeight / 2, 0, gBufferFormat[i], gBufferName[i] + "1");
        }

        // create depth
        cbrDepth0 = CreateCBRTexture(mainCam.pixelWidth / 2, mainCam.pixelHeight / 2, 32, RenderTextureFormat.Depth, "CBR Depth 0");
        cbrDepth1 = CreateCBRTexture(mainCam.pixelWidth / 2, mainCam.pixelHeight / 2, 32, RenderTextureFormat.Depth, "CBR Depth 1");

        // cache created buffer
        for (int i = 0; i < NumOfGBuffer; i++)
        {
            if (!CacheNativeGBuffer(cbrGBuffer0[i].GetNativeTexturePtr(), 0, i))
            {
                Debug.LogError("Init " + cbrGBuffer0[i].name + " failed.");
                enabled = false;
                return;
            }

            if (!CacheNativeGBuffer(cbrGBuffer1[i].GetNativeTexturePtr(), 1, i))
            {
                Debug.LogError("Init " + cbrGBuffer1[i].name + " failed.");
                enabled = false;
                return;
            }
        }

        if (!CacheNativeDepth(cbrDepth0.GetNativeDepthBufferPtr(), 0))
        {
            Debug.LogError("Init " + cbrDepth0.name + " failed.");
            enabled = false;
            return;
        }

        if (!CacheNativeDepth(cbrDepth1.GetNativeDepthBufferPtr(), 1))
        {
            Debug.LogError("Init " + cbrDepth1.name + " failed.");
            enabled = false;
            return;
        }

        // before gbuffer, set view port to CBR & set custom 2x MSAA GBuffer
        setCbrGBuffer = new CommandBuffer();
        setCbrGBuffer.name = "Set CBR GBuffer";
        setCbrGBuffer.SetViewport(cbrRect);
        setCbrGBuffer.IssuePluginEvent(GetRenderEventFunc(), 0);

        // after gbuffer, restore view port to main camera & compose cbr into Unity's GBuffer
        composeCbrGBuffer = new CommandBuffer();
        composeCbrGBuffer.name = "Compose CBR GBuffer";
        composeCbrGBuffer.SetViewport(mainCam.pixelRect);

        composeCbrGBuffer.SetGlobalTexture("_CbrDiffuse0", cbrGBuffer0[0]);
        composeCbrGBuffer.SetGlobalTexture("_CbrDiffuse1", cbrGBuffer1[0]);
        composeCbrGBuffer.SetGlobalTexture("_CbrSpecular0", cbrGBuffer0[1]);
        composeCbrGBuffer.SetGlobalTexture("_CbrSpecular1", cbrGBuffer1[1]);
        composeCbrGBuffer.SetGlobalTexture("_CbrNormal0", cbrGBuffer0[2]);
        composeCbrGBuffer.SetGlobalTexture("_CbrNormal1", cbrGBuffer1[2]);
        composeCbrGBuffer.SetGlobalTexture("_CbrEmission0", cbrGBuffer0[3]);
        composeCbrGBuffer.SetGlobalTexture("_CbrEmission1", cbrGBuffer1[3]);
        composeCbrGBuffer.SetGlobalTexture("_CbrShadowMask0", cbrGBuffer0[4]);
        composeCbrGBuffer.SetGlobalTexture("_CbrShadowMask1", cbrGBuffer1[4]);
        composeCbrGBuffer.SetGlobalTexture("_CbrDepth0", cbrDepth0);
        composeCbrGBuffer.SetGlobalTexture("_CbrDepth1", cbrDepth1);

        // compose gbuffer using mrt
        composeCbrGBuffer.IssuePluginEvent(GetRenderEventFunc(), 1);
        composeCbrGBuffer.DrawMesh(customQuad, Matrix4x4.identity, composeCBR, 0, 0);

        //composeCbrGBuffer.Blit(null, BuiltinRenderTextureType.CameraTarget, composeDepthCBR);
    }

    void ComposeCBR(RenderTexture _cbrRT0, RenderTexture _cbrRT1, RenderTargetIdentifier _dst, Material _mat)
    {
        if (_cbrRT0)
        {
            composeCbrGBuffer.SetGlobalTexture("_CbrFrame0", _cbrRT0);
        }

        if (_cbrRT1)
        {
            composeCbrGBuffer.SetGlobalTexture("_CbrFrame1", _cbrRT1);
        }

        composeCbrGBuffer.SetRenderTarget(_dst);
        composeCbrGBuffer.DrawMesh(customQuad, Matrix4x4.identity, composeCBR, 0, 0);
    }

    RenderTexture CreateCBRTexture(int _width, int _height, int _depth, RenderTextureFormat _format, string _name)
    {
        RenderTexture rt = new RenderTexture(_width, _height, _depth, _format, RenderTextureReadWrite.Linear);
        rt.name = _name;
        rt.antiAliasing = 2;
        rt.bindTextureMS = true;
        rt.Create();

        return rt;
    }

    void ReleaseCBR()
    {
        for (int i = 0; i < NumOfGBuffer; i++)
        {
            if (cbrGBuffer0 != null)
            {
                SafeRelease(ref cbrGBuffer0[i]);
            }

            if (cbrGBuffer1 != null)
            {
                SafeRelease(ref cbrGBuffer1[i]);
            }
        }
        SafeRelease(ref cbrDepth0);
        SafeRelease(ref cbrDepth1);
    }

    void SafeRelease(ref RenderTexture _rt)
    {
        if (_rt)
        {
            _rt.Release();
            DestroyImmediate(_rt);
        }
    }
}
